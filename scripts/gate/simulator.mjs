// The simulator tier: the hosted test bundle, then the journeys, on the gate's own simulator. `just simulator`
// runs it, and it is step 5 of the gate. See "The simulator tier" in docs/development.md.
//
// It builds as `just build` does, with the same arguments, and runs the tests from that build's `.xctestrun`
// file. Under the gate (`--no-build`), it doesn't build: step 4 is `just build`, so it runs step 4's build.
//
// The journeys run twice. In the first run, each screen that the journeys reach is audited in the four settings
// of the audit, once: the journey asks this script's settings helper, a small HTTP server on the Mac, whether a
// screen is new in the run, and to put the simulator in each setting with `simctl`. The second run is in the
// double-length pseudo-language, which needs a new launch.
//
// Every `xcodebuild` writes its log, and its result bundle, to the results folder. The script prints one line for
// each run. A run of the journeys that fails with the named flake "the app's launch gets no process ID on a busy
// machine" runs again, once (`runAgainOnLaunchFlake`).

import { execFile, execFileSync, spawn } from 'node:child_process';
import { createWriteStream, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync } from 'node:fs';
import { createServer } from 'node:http';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import { duration } from './gate.mjs';
import { judge } from './reading.mjs';
import { inSlot, slotDirectory } from './slot.mjs';
import { checkAuditScreenshots, readAttachmentNames, readResultBundle } from './xcresult.mjs';

/** The name of the gate's own simulator. The gate makes it when the machine has none. */
export const simulatorName = 'Wishbone gate';

/** The device that the gate's simulator is, when the newest iOS has it. Otherwise it is that iOS's first iPhone. */
const preferredDevice = 'iPhone 18 Pro';

/**
 * The arguments of the one build of the app and its test bundles, for the simulator, in `xcodebuild`'s order.
 * `just build` (step 4 of the gate) builds with these, and so does this script, so the simulator step reuses
 * step 4's build. A gate test holds the justfile to them.
 */
export const buildArguments = [
  'build-for-testing',
  '-project',
  'Wishbone.xcodeproj',
  '-scheme',
  'Wishbone',
  '-configuration',
  'Debug',
  '-destination',
  'generic/platform=iOS Simulator',
  '-derivedDataPath',
  'build/DerivedData',
  'ARCHS=arm64',
];

/**
 * The settings of the accessibility audit: the default, the largest accessibility text size, dark mode, and
 * Increase Contrast. A journey audits each screen in each of them, in one run. It asks the settings helper for
 * each one by its name, and the helper puts the simulator in it, with every other setting at its default.
 */
export const settings = [
  { name: 'default', label: 'the default settings' },
  { name: 'largest-text', label: 'the largest text size', contentSize: 'accessibility-extra-extra-extra-large' },
  { name: 'dark-mode', label: 'dark mode', appearance: 'dark' },
  { name: 'increase-contrast', label: 'Increase Contrast', increaseContrast: 'enabled' },
];

/**
 * The runs of the journeys. In the first, each journey audits in each of the settings. The second is in the
 * double-length pseudo-language, which shows text that is cut short, and text that is not in the String Catalog.
 * It audits in the default settings.
 */
export const journeyRuns = [
  { name: 'settings', label: 'the four settings of the audit', helper: true },
  { name: 'double-length', label: 'the double-length pseudo-language', doubleLength: true },
];

/**
 * Reads the script's arguments: the results folder, then the flags, in any order. `--no-build` runs the tests that
 * `just build` built. A word that starts with `--` is a flag, never the folder.
 */
export function parseArguments(args) {
  const known = ['--no-build'];
  const flags = args.filter((arg) => arg.startsWith('--'));
  const words = args.filter((arg) => !arg.startsWith('--'));
  const unknown = flags.filter((flag) => !known.includes(flag));
  if (unknown.length > 0) throw new Error(`unknown flag ${unknown.join(', ')}. The flag is ${known.join(', ')}`);
  if (words.length > 1) throw new Error(`one results folder, not ${words.length}: ${words.join(', ')}`);
  return { results: words[0] ?? path.join('build', 'simulator'), build: !flags.includes('--no-build') };
}

/** The result bundles of a run, for `checkResultBundles`: the hosted tests, and each run of the journeys. */
export function resultBundles(directory) {
  return {
    hosted: [{ path: path.join(directory, 'hosted.xcresult'), label: 'the hosted tests' }],
    ui: journeyRuns.map((run) => ({ path: path.join(directory, `journeys-${run.name}.xcresult`), label: `the journeys in ${run.label}` })),
  };
}

/** The number of Swift files that the build in the log compiled. */
export function compiledFiles(log) {
  return readFileSync(log, 'utf8')
    .split('\n')
    .filter((line) => /^(SwiftCompile|CompileSwift) /.test(line)).length;
}

/** The `.xctestrun` file that the build wrote to the products folder. The build writes one. */
export function findTestRun(productsDirectory) {
  const found = readdirSync(productsDirectory).filter((name) => name.endsWith('.xctestrun'));
  if (found.length !== 1) throw new Error(`the build left ${found.length} .xctestrun files in ${productsDirectory}, not one`);
  return path.join(productsDirectory, found[0]);
}

/** The numbers of a version, such as `27.2`, for a comparison. */
function numbers(version) {
  return String(version).split('.').map(Number);
}

function isNewer(one, other) {
  const [a, b] = [numbers(one), numbers(other)];
  for (let index = 0; index < Math.max(a.length, b.length); index += 1) {
    if ((a[index] ?? 0) !== (b[index] ?? 0)) return (a[index] ?? 0) > (b[index] ?? 0);
  }
  return false;
}

/**
 * Picks the runtime and the device type of a new simulator, from what `simctl list runtimes --json` gives: the
 * newest iOS that is available and has the preferred device, or else the newest iOS with any iPhone.
 * Returns `{ runtime, deviceType }` as identifiers, or null when the machine has no iOS runtime with an iPhone.
 */
export function pickDevice(runtimes, preferred = preferredDevice) {
  const candidates = (runtimes ?? [])
    .filter((runtime) => runtime.isAvailable && runtime.platform === 'iOS')
    .map((runtime) => {
      const iPhones = (runtime.supportedDeviceTypes ?? []).filter((type) => type.productFamily === 'iPhone');
      return { runtime, device: iPhones.find((type) => type.name === preferred) ?? null, any: iPhones[0] ?? null };
    })
    .filter((candidate) => candidate.any !== null)
    .sort((one, other) => (isNewer(one.runtime.version, other.runtime.version) ? -1 : isNewer(other.runtime.version, one.runtime.version) ? 1 : 0));
  const best = candidates.find((candidate) => candidate.device !== null) ?? candidates[0];
  if (best === undefined) return null;
  return { runtime: best.runtime.identifier, deviceType: (best.device ?? best.any).identifier };
}

/** The gate's simulators in what `simctl list devices --json` gives: `[{ udid, state, isAvailable }]`. */
export function gateSimulators(devices, name = simulatorName) {
  return Object.values(devices ?? {})
    .flat()
    .filter((device) => device.name === name);
}

function simctl(args, options = {}) {
  return execFileSync('xcrun', ['simctl', ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], ...options });
}

/** The ID of the gate's own simulator. It makes the simulator when the machine has none that it can use. */
export function findOrMakeSimulator() {
  const all = gateSimulators(JSON.parse(simctl(['list', 'devices', '--json'])).devices);
  const usable = all.find((device) => device.isAvailable);
  if (usable !== undefined) return usable.udid;
  // A simulator whose iOS is gone can't start. A new one takes its place.
  for (const device of all) simctl(['delete', device.udid]);
  const picked = pickDevice(JSON.parse(simctl(['list', 'runtimes', '--json'])).runtimes);
  if (picked === null) throw new Error('this Mac has no iOS simulator runtime with an iPhone. Install one in Xcode, in Settings, Components');
  return simctl(['create', simulatorName, picked.deviceType, picked.runtime]).trim();
}

/**
 * Shuts the gate's own simulator down. The simulator belongs to the system, not to the step that started it, so
 * stopping the step's processes leaves it running. It is no error when there is none, or when it is shut down.
 */
export function shutDownSimulator() {
  try {
    for (const device of gateSimulators(JSON.parse(simctl(['list', 'devices', '--json'])).devices)) {
      if (device.state !== 'Shutdown') simctl(['shutdown', device.udid]);
    }
  } catch {
    // The Mac has no `simctl`, or the simulator went by itself.
  }
}

/** The `simctl` calls that put the simulator in the setting, with every other setting at its default. */
export function settingCommands(setting, simulator) {
  return [
    ['ui', simulator, 'appearance', setting.appearance ?? 'light'],
    ['ui', simulator, 'increase_contrast', setting.increaseContrast ?? 'disabled'],
    ['ui', simulator, 'content_size', setting.contentSize ?? 'large'],
  ];
}

/** How long one `simctl` call that changes a setting for a journey may take, before it counts as hung. */
export const settingCallLimitMs = 30_000;

/** How long a call that reads a setting back, after a hang, may take. */
export const settingReadLimitMs = 10_000;

/** How long the applier waits after a hang, before it reads the setting back and runs the call again. */
export const settingPauseMs = 5_000;

/**
 * The longest time that the helper takes to answer a journey. An `apply` never starts a call that could end after
 * it, so a call that keeps hanging fails the setting within it. `helperTimeout` in `JourneyTests/Audit.swift` is
 * longer, so a journey gets the helper's own error, which names the call, not a request that timed out.
 */
export const helperAnswerLimitMs = 180_000;

/**
 * How long a `simctl` call may take at the step's start. Just after a new simulator's first boot, its calls wait
 * minutes for the simulator to be ready, so they are not hung until much later than a journey's.
 */
export const readinessCallLimitMs = 5 * 60_000;

/**
 * The time that the step's first `apply`, with its longer calls, may take: a call can hang once, be read back, and
 * run again. Each call that `apply` starts must fit its whole limit in the time left, so after a hang and a slow
 * second try, a later call of the change isn't run, and the change fails. A journey's change that runs all three
 * calls is the same: a call that hangs until the time is up leaves the others no time.
 */
export const readinessAnswerLimitMs = 3 * readinessCallLimitMs;

/**
 * Runs `xcrun simctl <args>`, and stops it when it passes `limitMs`. Resolves when it ends well. Rejects when it
 * fails, and with an error whose `timedOut` is true when it passed its limit.
 */
export function simctlWithLimit(args, limitMs = settingCallLimitMs, { file = 'xcrun', prefix = ['simctl'] } = {}) {
  return new Promise((resolve, reject) => {
    execFile(file, [...prefix, ...args], { timeout: limitMs, killSignal: 'SIGKILL', encoding: 'utf8' }, (error, stdout, stderr) => {
      if (error === null) {
        resolve(stdout);
        return;
      }
      const failure = new Error(error.killed ? `didn't return within ${duration(limitMs)}` : (stderr.trim() || error.message));
      failure.timedOut = error.killed === true;
      reject(failure);
    });
  });
}

/**
 * Puts the simulator in a setting, and every other setting back to its default, with `run(command, limitMs)` (a
 * `simctl` call with a time limit, `simctlWithLimit`). It remembers what it set, and runs only the calls that
 * change something: a change from the default to one setting, and back, is one call each way, not three. Its first
 * `apply` runs every call, because the simulator can be in any setting from an earlier run.
 *
 * A call that passes its limit is hung. This is the named flake "a `simctl ui` call hangs on a CI runner" in
 * docs/development.md: the simulator stops answering a call for a minute or more, and then answers again. So after
 * a hang, the applier waits `pauseMs`, and reads the setting back (`simctl ui <device> <option>`, with a limit of
 * `readLimitMs`). When the setting reads as the value, the hung call did its work, and the applier goes on. When it
 * doesn't, it runs the call again. It does this while the apply has time left: it never starts a call or a read
 * that could end after `answerLimitMs` from the apply's start. Then a call that still hangs fails the setting, with
 * an error that names the setting, the call, and how many times it hung. So a hang in CI shows as itself, not as a
 * journey's request that timed out. A call that fails in any other way fails the setting at once.
 *
 * `apply` takes `{ limitMs, answerLimitMs }`, which are `limitMs` and `answerLimitMs` unless it says otherwise.
 *
 * It applies one setting at a time: an `apply` that comes while another runs waits for it, also when that one
 * fails. So a journey whose request timed out leaves no call running beside the next journey's.
 *
 * `now` and `sleep` are the clock, so a test runs it on its own clock.
 *
 * Returns `{ apply(setting, { limitMs, answerLimitMs }), calls(), hangs(), ms() }`: the number of calls that changed
 * a setting, how many of them hung, and the time that the changes took.
 */
export function settingsApplier(
  simulator,
  {
    run = simctlWithLimit,
    limitMs = settingCallLimitMs,
    answerLimitMs = helperAnswerLimitMs,
    readLimitMs = settingReadLimitMs,
    pauseMs = settingPauseMs,
    now = Date.now,
    sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  } = {},
) {
  const set = new Map();
  let calls = 0;
  let hangs = 0;
  let ms = 0;
  let queue = Promise.resolve();
  const applyNow = async (setting, callLimitMs, applyLimitMs) => {
    const started = now();
    const fits = (limit) => now() - started + limit <= applyLimitMs;
    /** The setting as the simulator reads it, or null when the read fails or hangs. */
    const readBack = async (command) => {
      if (!fits(readLimitMs)) return null;
      try {
        return (await run(command.slice(0, 3), readLimitMs)).trim();
      } catch {
        return null;
      }
    };
    for (const command of settingCommands(setting, simulator)) {
      const [, , name, value] = command;
      if (set.get(name) === value) continue;
      const callStarted = now();
      // A call that fails leaves the setting unknown, so the next `apply` runs it again.
      set.delete(name);
      let hung = 0;
      try {
        for (;;) {
          if (!fits(callLimitMs)) {
            if (hung === 0) throw new Error(`wasn't run: the change's earlier calls took its ${duration(applyLimitMs)}`);
            const times = hung === 1 ? 'once' : hung === 2 ? 'twice' : `${hung} times`;
            throw new Error(`didn't return within ${duration(callLimitMs)}, ${times} in ${duration(now() - callStarted)}`);
          }
          calls += 1;
          try {
            await run(command, callLimitMs);
            break;
          } catch (error) {
            if (!error.timedOut) throw error;
            hung += 1;
            hangs += 1;
          }
          await sleep(Math.min(pauseMs, Math.max(0, applyLimitMs - (now() - started))));
          if ((await readBack(command)) === value) break;
        }
      } catch (error) {
        throw new Error(`simctl ${command.join(' ')} ${error.message}, so the simulator isn't in ${setting.label}`);
      } finally {
        ms += now() - callStarted;
      }
      set.set(name, value);
    }
  };
  return {
    apply(setting, { limitMs: callLimitMs = limitMs, answerLimitMs: applyLimitMs = answerLimitMs } = {}) {
      const applied = queue.then(() => applyNow(setting, callLimitMs, applyLimitMs));
      queue = applied.catch(() => {});
      return applied;
    },
    calls: () => calls,
    hangs: () => hangs,
    ms: () => ms,
  };
}

/**
 * The settings helper: an HTTP server on the Mac's loopback, at a free port, that a journey asks to put the
 * simulator in a setting. `POST /settings/<name>` applies the setting of that name with `applySetting`, and
 * answers 204 when it is applied. A name that is not a setting gets 404. The journey gets the helper's address in
 * its environment, because a test can't change text size or Increase Contrast from inside the simulator.
 *
 * It also knows which screens the run has audited. `POST /screens`, with a screen's name as the body, answers
 * 201 when the name is new in the run, so the journey audits the screen, and 200 when a journey audited it
 * already, so the journey doesn't audit it again. Only the run in the four settings has a helper, and it starts
 * its own, so the screens that it remembers are that run's.
 *
 * Resolves with `{ address, close, screens }`, where `screens()` gives the names, in the order they came.
 */
export function startSettingsHelper(applySetting) {
  const screens = new Set();
  const server = createServer((request, response) => {
    if (request.url === '/screens') {
      if (request.method !== 'POST') {
        response.writeHead(404).end();
        return;
      }
      const body = [];
      request.on('data', (chunk) => body.push(chunk));
      request.on('end', () => {
        const screen = Buffer.concat(body).toString('utf8');
        if (screen === '') {
          response.writeHead(400, { 'Content-Type': 'text/plain' }).end("a screen's name, as the body");
          return;
        }
        const isNew = !screens.has(screen);
        screens.add(screen);
        response.writeHead(isNew ? 201 : 200).end();
      });
      return;
    }
    const match = /^\/settings\/([a-z-]+)$/.exec(request.url ?? '');
    const setting = settings.find((one) => one.name === match?.[1]);
    if (request.method !== 'POST' || setting === undefined) {
      response.writeHead(404).end();
      return;
    }
    Promise.resolve()
      .then(() => applySetting(setting))
      .then(
        () => response.writeHead(204).end(),
        (error) => response.writeHead(500, { 'Content-Type': 'text/plain' }).end(String(error?.message ?? error)),
      );
  });
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      resolve({
        address: `http://127.0.0.1:${server.address().port}`,
        close: () => new Promise((done) => server.close(() => done())),
        screens: () => [...screens],
      });
    });
  });
}

/**
 * A screenshot shows the status bar, and its clock moves. The journey waits for the screen to show a setting by
 * comparing screenshots, so the clock and the rest of the bar are held still.
 */
function holdStatusBar(simulator) {
  simctl(['status_bar', simulator, 'override', '--time', '9:41', '--dataNetwork', 'wifi', '--wifiBars', '3', '--batteryState', 'charged', '--batteryLevel', '100']);
}

/**
 * Boots the gate's simulator, holds its status bar still, and puts it in the default settings, with a line for
 * each part and its time. Returns `{ simulator, applier }`: the
 * simulator's ID, and the `settingsApplier` that knows its settings.
 */
export async function prepareSimulator({ say = console.log } = {}) {
  const timed = async (what, work) => {
    const started = Date.now();
    const result = await work();
    say(`✓ ${what} (${duration(Date.now() - started)})`);
    return result;
  };
  const simulator = await timed("Found the gate's simulator", findOrMakeSimulator);
  await timed("Booted the gate's simulator", () => simctl(['bootstatus', simulator, '-b'], { stdio: 'ignore' }));
  await timed("Held the simulator's status bar still", () => holdStatusBar(simulator));
  const applier = settingsApplier(simulator);
  await timed('Put the simulator in the default settings', () => applier.apply(settings[0], { limitMs: readinessCallLimitMs, answerLimitMs: readinessAnswerLimitMs }));
  return { simulator, applier };
}

/**
 * The named flake "the app's launch gets no process ID on a busy machine" in docs/development.md. XCTest's
 * `launch()` waits for the app's process, and on a machine under very high load it gives up with "Application
 * '<bundle ID>' does not have a process ID". The app's code never ran. On CI, the test runner then failed too, and
 * Xcode reports that as a test of its own, named "<runner> (<pid>) encountered an error".
 */
export const launchFlake = {
  name: "the app's launch gets no process ID on a busy machine",
  message: /Application '[^']+' does not have a process ID/,
  runner: /-Runner \(\d+\) encountered an error$/,
};

/**
 * Whether a reading of a run of the journeys failed with the launch flake's signature, and nothing else: at least
 * one test failed, and each of its failure messages is the launch that got no process ID, and every other failure
 * is the test runner's error. A launch that got its process ID and then crashed has another message, so it stays
 * red, and so does a runner's error with no launch that failed.
 *
 * Returns the names of the tests whose launch failed, or null when the failure isn't the flake.
 */
export function launchFlakeIn(reading) {
  if (reading.tests === null || reading.failed.length === 0) return null;
  const messages = (name) => reading.messages?.[name] ?? [];
  const launches = reading.failed.filter((name) => messages(name).length > 0 && messages(name).every((message) => launchFlake.message.test(message)));
  if (launches.length === 0) return null;
  const others = reading.failed.filter((name) => !launches.includes(name));
  return others.every((name) => launchFlake.runner.test(name)) ? launches : null;
}

/**
 * Runs `runOnce` (a run of the journeys, which resolves with `{ passed, reading }`), and runs it again once when it
 * failed with the launch flake's signature (`launchFlakeIn`). Before the second run, `keep()` moves the first
 * run's files aside, and returns where they are, for the line. Any other failure, and a second run that fails in
 * any way, is red. Resolves with whether the last run passed.
 */
export async function runAgainOnLaunchFlake(runOnce, { keep, say = console.log }) {
  const first = await runOnce();
  const launches = first.passed ? null : launchFlakeIn(first.reading);
  if (launches === null) return first.passed;
  const kept = keep();
  say(`  ${launches.join(', ')}: the launch got no process ID (the named flake "${launchFlake.name}"), so these journeys run again, once. The first run is in ${kept.join(' and ')}.`);
  return (await runOnce()).passed;
}

/**
 * Moves the result bundle and the log of a run that the gate runs again to names of their own, `<name>-first`, so
 * the second run writes its own at the run's paths. Returns the new paths.
 */
export function keepFirstTry(directory, bundle, log) {
  const keptBundle = bundle.replace(/\.xcresult$/, '-first.xcresult');
  const keptLog = path.join(directory, log.replace(/\.log$/, '-first.log'));
  rmSync(keptBundle, { recursive: true, force: true });
  rmSync(keptLog, { force: true });
  if (existsSync(bundle)) renameSync(bundle, keptBundle);
  if (existsSync(path.join(directory, log))) renameSync(path.join(directory, log), keptLog);
  return [keptBundle, keptLog];
}

/** Runs `xcodebuild` with its output in a log file. Resolves with its exit code. */
function xcodebuild(args, { root, log, env = {} }) {
  return new Promise((resolve, reject) => {
    const output = createWriteStream(log);
    const child = spawn('xcodebuild', args, { cwd: root, env: { ...process.env, ...env }, stdio: ['ignore', 'pipe', 'pipe'] });
    child.stdout.pipe(output, { end: false });
    child.stderr.pipe(output, { end: false });
    child.on('error', reject);
    child.on('close', (code) => output.end(() => resolve(code ?? 1)));
  });
}

/**
 * Builds the app and the test bundles, and runs the hosted tests and then the journeys. The first run that fails
 * ends it. Returns true when every run passed.
 *
 * With `build: false`, it doesn't build: it runs the tests that `just build` built. The gate asks for that, because
 * its step 4 has just built them. On CI, a build next to a newly booted simulator took minutes, even with nothing
 * to compile.
 */
export async function runSimulatorTier({ root, directory, build = true, say = console.log }) {
  rmSync(directory, { recursive: true, force: true });
  mkdirSync(directory, { recursive: true });
  const relative = (file) => path.relative(root, file);

  /**
   * One `xcodebuild` run, with its line. `bundle` is the result bundle that the run writes, if it runs tests.
   * Resolves with whether it passed. `onReading`, if given, gets the reading of its bundle.
   */
  const run = async (what, args, { log, bundle, env, onReading }) => {
    const started = Date.now();
    const exit = await xcodebuild(args, { root, log: path.join(directory, log), env });
    const reading = bundle === undefined ? null : readResultBundle(bundle);
    onReading?.(reading);
    const problem = reading === null ? null : judge(reading);
    const ok = exit === 0 && problem === null;
    const why = problem ?? `xcodebuild ended with ${exit}`;
    // The rest of a run's time is Xcode's own: installing the app, and launching the test runner.
    const tests = reading?.testsMs == null ? '' : `, the tests ${duration(reading.testsMs)}`;
    say(ok ? `✓ ${what} (${duration(Date.now() - started)}${tests})` : `✗ ${what}: ${why} (log: ${relative(path.join(directory, log))})`);
    return ok;
  };

  let helper = null;
  let simulator = null;
  let applier = null;
  try {
    ({ simulator, applier } = await prepareSimulator({ say }));
    if (build) {
      if (!(await run('Built the app and the test bundles for the simulator', buildArguments, { log: 'build.log' }))) return false;
      // After `just build`, the build has nothing to compile. The line says so.
      say(`  It compiled ${compiledFiles(path.join(directory, 'build.log'))} Swift files.`);
    }
    const testRun = findTestRun(path.join(root, 'build', 'DerivedData', 'Build', 'Products'));
    if (!build) say(`✓ Took the app and the test bundles from the gate's build step (${relative(testRun)})`);

    const bundles = resultBundles(directory);
    const test = (only, bundle) => [
      'test-without-building',
      '-xctestrun',
      testRun,
      '-destination',
      `platform=iOS Simulator,id=${simulator}`,
      `-only-testing:${only}`,
      '-resultBundlePath',
      bundle,
      '-parallel-testing-enabled',
      'NO',
    ];
    if (!(await run('The hosted tests', test('HostedTests', bundles.hosted[0].path), { log: 'hosted.log', bundle: bundles.hosted[0].path }))) return false;

    for (const [index, journeys] of journeyRuns.entries()) {
      const bundle = bundles.ui[index].path;
      const log = `journeys-${journeys.name}.log`;
      /** One run of these journeys, with a new helper. Resolves with whether it passed, and its reading. */
      const runJourneys = async () => {
        await applier.apply(settings[0]);
        const helperCalls = applier.calls();
        const helperHangs = applier.hangs();
        const helperMs = applier.ms();
        // Only the run in the four settings has a helper, so the screens that it remembers are that run's.
        await helper?.close();
        helper = journeys.helper ? await startSettingsHelper((setting) => applier.apply(setting)) : null;
        // xcodebuild gives the test runner each variable that starts with TEST_RUNNER_, without that start.
        const env = {
          TEST_RUNNER_WISHBONE_SETTINGS_HELPER: helper?.address ?? '',
          TEST_RUNNER_WISHBONE_DOUBLE_LENGTH: journeys.doubleLength ? 'YES' : 'NO',
        };
        let reading = null;
        const passed = await run(`The journeys in ${journeys.label}`, test('JourneyTests', bundle), { log, bundle, env, onReading: (one) => (reading = one) });
        if (journeys.helper) {
          const hung = applier.hangs() - helperHangs;
          const again = hung === 0 ? '' : `, and ${hung} of them hung (the named flake "a \`simctl ui\` call hangs on a CI runner")`;
          say(`  The settings helper made ${applier.calls() - helperCalls} simctl calls, in ${duration(applier.ms() - helperMs)}${again}.`);
        }
        return { passed, reading };
      };
      const passed = await runAgainOnLaunchFlake(runJourneys, {
        // The first run's bundle and log stay, under other names, for a person to look at. The gate reads only the
        // second run's bundle, at the run's own path.
        keep: () => keepFirstTry(directory, bundle, log).map(relative),
        say,
      });
      if (!passed) return false;
      if (journeys.helper) {
        // The result bundle must have each screen that the helper audited, in the four settings, once, and no other.
        const labels = settings.map((setting) => setting.label);
        const { screens, problem } = checkAuditScreenshots(readAttachmentNames(bundle), labels, helper.screens());
        if (problem !== null) {
          say(`✗ The audit's screenshots in ${relative(bundle)}: ${problem}`);
          return false;
        }
        say(`  The journeys audited ${screens} screens, each in the four settings once.`);
      }
    }
    return true;
  } finally {
    await helper?.close();
    try {
      if (simulator !== null) {
        await applier.apply(settings[0]);
        simctl(['status_bar', simulator, 'clear']);
      }
    } catch {
      // The simulator is gone. The next run starts it, and sets it again.
    }
    shutDownSimulator();
  }
}

if (import.meta.main) {
  const root = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8', cwd: path.dirname(fileURLToPath(import.meta.url)) }).trim();
  try {
    const { results, build } = parseArguments(process.argv.slice(2));
    const directory = path.resolve(root, results);
    // Under the gate, the gate holds the slot. By itself, the run takes it, so it never breaks another
    // checkout's gate on the one simulator.
    const passed = await inSlot(() => runSimulatorTier({ root, directory, build }), {
      directory: slotDirectory(),
      owner: `just simulator in ${root} (process ${process.pid})`,
      onWait: (holder) => console.log(`── waiting for the gate slot${holder === '' ? '' : `, which ${holder} holds`}`),
    });
    process.exit(passed ? 0 : 1);
  } catch (error) {
    console.error(`✗ The simulator tests: ${error.message}`);
    process.exit(1);
  }
}
