// `just gate`: every check that a pull request must pass. See "The gate" in docs/development.md.
//
// Its last line is the result, for example `GATE PASS package=34 hosted=0 ui=0 · 1m12s`.

import { execFileSync } from 'node:child_process';
import path from 'node:path';
import process from 'node:process';

import { acknowledgementsFile } from '../acknowledgements.mjs';
import { builtServerProblem } from '../server/build.mjs';
import { readFloor, runGate } from './gate.mjs';
import { checkEventStream } from './reading.mjs';
import { resultBundles, shutDownSimulator } from './simulator.mjs';
import { slotDirectory } from './slot.mjs';
import { checkResultBundles } from './xcresult.mjs';

const minute = 60_000;
const root = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim();
const gateDirectory = path.join(root, 'build', 'gate');
const runDirectory = path.join(gateDirectory, 'run');
const floorFile = path.join(root, 'scripts', 'gate', 'floor.json');
const packageEvents = path.join(runDirectory, 'package-events.jsonl');
const simulatorDirectory = path.join(runDirectory, 'simulator');

// The tests that may be skipped, or may cancel themselves. Each entry is a test's name as the gate prints it
// (`Module.Suite/function()`), with a comment that says why. A skipped or cancelled test that is not here fails
// the gate.
const allowedSkips = [];

// Keep the sum of the steps' limits under the Gate job's `timeout-minutes` in .github/workflows/ci.yml. If the
// sum is over it, the job's limit can cut the gate off before a step's limit does, and the run ends with no
// result line. A step that is skipped gets its limit when it gets its command.
const steps = [
  {
    name: 'lint',
    command: ['just', 'lint'],
    // Most of the step is the gate's own tests (`just test-gate`), which take about 10 seconds on a quiet machine.
    // Under the shared machine's normal load they have taken up to about 140 seconds (a load of 275 to 757), so the
    // limit is about twice that.
    limitMs: 5 * minute,
  },
  {
    name: 'server',
    command: ['just', 'server'],
    // A first build fetches the server's source, and can install the Go that it names.
    limitMs: 10 * minute,
    check: ({ exit }) => {
      if (exit !== 0) return {};
      // The step must leave a server that the package tests can start: built from the pin, and stamped.
      const problem = builtServerProblem(root);
      return problem === null ? {} : { fail: problem };
    },
  },
  {
    name: 'package',
    command: ['just', 'test', '--event-stream-output-path', packageEvents, '--event-stream-version', '0'],
    limitMs: 10 * minute,
    counts: ['package'],
    check: ({ exit, logPath }) => checkEventStream(packageEvents, { exit, countName: 'package', allowedSkips, xctestLog: logPath }),
  },
  {
    name: 'build',
    command: ['just', 'build'],
    limitMs: 15 * minute,
    slot: true,
    check: ({ exit }) => {
      if (exit !== 0) return {};
      // The build adds new strings to the String Catalog, and makes the Acknowledgements from the pinned
      // packages. A file that differs from the commit means that the commit doesn't hold what the build makes.
      const made = [':(glob)**/*.xcstrings', acknowledgementsFile];
      const changed = execFileSync('git', ['status', '--porcelain', '--', ...made], { cwd: root, encoding: 'utf8' })
        .split('\n')
        .filter((line) => line !== '')
        .map((line) => line.slice(3));
      return changed.length > 0 ? { fail: `the build changed what is in git. Commit ${changed.join(', ')}` } : {};
    },
  },
  {
    name: 'simulator',
    // Step 4 (`just build`) has built the app and the test bundles, so this step doesn't build them again.
    command: ['just', 'simulator', path.relative(root, simulatorDirectory), '--no-build'],
    // A first run starts a new simulator. Then come the hosted tests, and the journeys twice: with the audit in
    // the four settings, and in the double-length pseudo-language. On a new CI runner, the step's fixed part (the
    // simulator's first boot, up to about 6 minutes, and the hosted tests) takes about 5m40s to 8 minutes. Each
    // screen that the journeys audit takes about 1 minute in the four settings, once in the run. Double length has
    // no helper, so it pays its 15 seconds or so each time that a journey reaches a screen. With both runs, about
    // 1m15s for each screen, 19 audited screens take about 32 minutes. The limit also holds a second run of the
    // journeys in the four settings, for the named flake "the app's launch gets no process ID on a busy machine":
    // with 19 screens, that run takes about 17 minutes, and a first try whose launch waits (about 3 minutes) and
    // then fails late costs nearly as much again. The named flake "a change of setting doesn't show in the app" sends
    // a change again: about 1m30s when one resend works, and up to about 5 minutes. So the step holds about 19
    // audited screens with one such second run and one resend, and about 40 with neither.
    limitMs: 60 * minute,
    slot: true,
    counts: ['hosted', 'ui'],
    check: ({ exit }) => checkResultBundles(resultBundles(simulatorDirectory), { exit, allowedSkips }),
    // The simulator belongs to the system, so stopping the step's processes at its limit leaves it running.
    after: shutDownSimulator,
  },
];

const interrupt = new AbortController();
for (const name of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(name, () => interrupt.abort());

let ok = false;
try {
  ({ ok } = await runGate({
    steps,
    floor: readFloor(floorFile),
    root,
    runDirectory,
    slotDirectory: slotDirectory(),
    timesFile: path.join(gateDirectory, 'times.jsonl'),
    floorFile: path.relative(root, floorFile),
    // The budget is for a warm run on the maintainer's laptop. A CI runner starts cold.
    budgetMs: process.env.CI ? Infinity : 5 * minute,
    owner: `the gate in ${root} (process ${process.pid})`,
    signal: interrupt.signal,
  }));
} catch (error) {
  console.log(`GATE FAIL before step 1: ${error.message}`);
}
process.exit(ok ? 0 : 1);
