// The gate's steps, in order. `just gate` (main.mjs) runs them all, and each part of the dispatched Gate run in CI
// runs some of them (parts.mjs). See "The gate" in docs/development.md.

import { execFileSync } from 'node:child_process';
import { readdirSync } from 'node:fs';
import path from 'node:path';

import { acknowledgementsFile } from '../acknowledgements.mjs';
import { builtServerProblem } from '../server/build.mjs';
import { parts, shardNamed, shardProblem } from './parts.mjs';
import { checkEventStream } from './reading.mjs';
import { resultBundles, shutDownSimulator } from './simulator.mjs';
import { checkResultBundles } from './xcresult.mjs';

const minute = 60_000;

// The tests that may be skipped, or may cancel themselves. Each entry is a test's name as the gate prints it
// (`Module.Suite/function()`), with a comment that says why. A skipped or cancelled test that is not here fails
// the gate.
export const allowedSkips = [];

/**
 * The limit of the simulator step of each shard of the journeys (parts.mjs), when CI runs the shards side by side.
 * Each shard's step has the simulator's start (on a new CI runner, up to about 6 minutes), the hosted tests if the
 * shard has them (about 2m20s), and its journeys, twice: in the four settings, and in the double-length
 * pseudo-language. Each limit is about twice what the shard took in CI, so that it holds a second run of its
 * journeys in the four settings for the named flake "the app's launch gets no process ID on a busy machine", and a
 * resend for the named flake "a change of setting doesn't show in the app".
 */
export const shardLimitMs = {
  'journeys-1': 40 * minute,
  'journeys-2': 40 * minute,
  'journeys-3': 40 * minute,
  'journeys-4': 40 * minute,
};

/**
 * The gate's steps, for the checkout at `root`. `runDirectory` holds the run's logs and results. With `part`, only
 * the steps of that part (parts.mjs), and for a shard of the journeys, its simulator step runs only that shard, with
 * the shard's own limit.
 */
export function gateSteps({ root, runDirectory, part }) {
  const packageEvents = path.join(runDirectory, 'package-events.jsonl');
  const simulatorDirectory = path.join(runDirectory, 'simulator');
  if (part !== undefined && parts[part] === undefined) throw new Error(`the gate has no part ${part}. Its parts are ${Object.keys(parts).join(', ')}`);
  const shard = part?.startsWith('journeys-') ? shardNamed(part) : undefined;

  // The processes whose crash reports a failed step keeps (see crashes.mjs). `swift test` runs each test target's
  // tests in a process of Xcode's (`swiftpm-testing-helper` for Swift Testing, `xctest` for XCTest) that loads the
  // target's test binary, so the report is known by that binary. The hosted tests run inside the app, and the
  // journeys drive the app and its extensions from a runner.
  const packageTestTargets = readdirSync(path.join(root, 'WishboneKit', 'Tests'));
  const packageCrashes = (report) =>
    ['swiftpm-testing-helper', 'xctest'].includes(report.process) && report.images.some((name) => packageTestTargets.includes(name));
  const simulatorCrashes = (report) => ['Wishbone', 'ShareExtension', 'WidgetExtension', 'JourneyTests-Runner'].includes(report.process);

  // Keep the sum of the steps' limits under the Gate job's `timeout-minutes` in .github/workflows/ci.yml, and the
  // sum of each part's under its job's. If the sum is over it, the job's limit can cut the gate off before a step's
  // limit does, and the run ends with no result line. A step that is skipped gets its limit when it gets its command.
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
      name: 'package-build',
      command: ['just', 'build-package'],
      // SwiftPM resolves the packages (on CI, it unpacks sentry-cocoa's frameworks from its cache, about 1m10s),
      // then builds the package and its tests. On CI on 2026-11-23, the step's part of the old package step took
      // 1m49s to 3m58s in 13 runs, and the build itself 60 to 151 seconds. The limit is about twice the slowest.
      limitMs: 8 * minute,
    },
    {
      name: 'package',
      command: ['just', 'test', '--skip-build', '--event-stream-output-path', packageEvents, '--event-stream-version', '0'],
      // Step 3 built the tests, so this step only runs them, and its time is the tests' own.
      // On CI on 2026-11-23, with 394 to 403 tests, the tests took 2m42s to 5m40s in 12 green runs, and more than
      // 6m18s in run 45187683978 attempt 1, which the old limit of 10 minutes for the build and the tests together
      // stopped. A runner has 3 cores for 8 tests at a time, so the time goes with the runner's speed. The limit is
      // about twice the slowest.
      limitMs: 12 * minute,
      counts: ['package'],
      check: ({ exit, logPath }) => checkEventStream(packageEvents, { exit, countName: 'package', allowedSkips, xctestLog: logPath }),
      crashes: packageCrashes,
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
      // Step 5 (`just build`) has built the app and the test bundles, so this step doesn't build them again. A
      // shard of the journeys runs the build part's build.
      command: ['just', 'simulator', path.relative(root, simulatorDirectory), '--no-build', ...(shard === undefined ? [] : [`--shard=${shard.name}`])],
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
      // audited screens with one such second run and one resend, and about 40 with neither. A shard has its own
      // limit, in `shardLimitMs`.
      limitMs: shard === undefined ? 60 * minute : shardLimitMs[shard.name],
      slot: true,
      counts: ['hosted', 'ui'],
      check: ({ exit }) => {
        const checked = checkResultBundles(resultBundles(simulatorDirectory, shard), { exit, allowedSkips });
        if (checked.fail !== undefined || shard === undefined || exit !== 0) return checked;
        // A shard's journeys must be its own, each once: so across the shards, each journey runs once.
        const problem = shardProblem(checked.names.ui ?? [], shard);
        return problem === null ? checked : { ...checked, fail: problem };
      },
      crashes: simulatorCrashes,
      // The simulator belongs to the system, so stopping the step's processes at its limit leaves it running.
      after: shutDownSimulator,
    },
  ];
  return part === undefined ? steps : steps.filter((step) => parts[part].includes(step.name));
}
