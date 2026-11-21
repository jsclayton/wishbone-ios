// `just gate`: every check that a pull request must pass. See "The gate" in docs/development.md.
//
// Its last line is the result, for example `GATE PASS package=34 hosted=0 ui=0 · 1m12s`.

import { execFileSync } from 'node:child_process';
import path from 'node:path';
import process from 'node:process';

import { readFloor, runGate } from './gate.mjs';
import { checkEventStream } from './reading.mjs';
import { slotDirectory } from './slot.mjs';

const minute = 60_000;
const root = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim();
const gateDirectory = path.join(root, 'build', 'gate');
const runDirectory = path.join(gateDirectory, 'run');
const floorFile = path.join(root, 'scripts', 'gate', 'floor.json');
const packageEvents = path.join(runDirectory, 'package-events.jsonl');

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
    limitMs: 2 * minute,
  },
  {
    name: 'server',
    skip: 'no test needs the test server yet',
  },
  {
    name: 'package',
    command: ['just', 'test', '--event-stream-output-path', packageEvents, '--event-stream-version', '0'],
    limitMs: 10 * minute,
    counts: ['package'],
    check: ({ exit }) => checkEventStream(packageEvents, { exit, countName: 'package', allowedSkips }),
  },
  {
    name: 'build',
    command: ['just', 'build'],
    limitMs: 15 * minute,
    slot: true,
    check: ({ exit }) => {
      if (exit !== 0) return {};
      // The build adds new strings to the String Catalog. A catalog that differs from the commit means that the
      // commit doesn't hold every string.
      const changed = execFileSync('git', ['status', '--porcelain', '--', ':(glob)**/*.xcstrings'], { cwd: root, encoding: 'utf8' })
        .split('\n')
        .filter((line) => line !== '')
        .map((line) => line.slice(3));
      return changed.length > 0 ? { fail: `the String Catalog changed. Commit ${changed.join(', ')}` } : {};
    },
  },
  {
    name: 'simulator',
    skip: 'no hosted test or journey exists yet',
    slot: true,
    counts: ['hosted', 'ui'],
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
