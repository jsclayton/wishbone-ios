// The simulator tier: the hosted test bundle, then the journeys, on the gate's own simulator. `just simulator`
// runs it, and it is step 5 of the gate. See "The simulator tier" in docs/development.md.
//
// It builds as `just build` (step 4) does, with the same arguments, so after step 4 its build has nothing to do.
// Then it runs the tests from that build's `.xctestrun` file.
//
// The journeys run twice. In the first run, each journey audits each screen in the four settings of the audit:
// the journey asks this script's settings helper, a small HTTP server on the Mac, to put the simulator in each
// setting with `simctl`. The second run is in the double-length pseudo-language, which needs a new launch.
//
// Every `xcodebuild` writes its log, and its result bundle, to the results folder. The script prints one line for
// each run.

import { execFileSync, spawn } from 'node:child_process';
import { createWriteStream, mkdirSync, readdirSync, rmSync } from 'node:fs';
import { createServer } from 'node:http';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import { duration } from './gate.mjs';
import { judge } from './reading.mjs';
import { inSlot, slotDirectory } from './slot.mjs';
import { readResultBundle } from './xcresult.mjs';

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

/** The result bundles of a run, for `checkResultBundles`: the hosted tests, and each run of the journeys. */
export function resultBundles(directory) {
  return {
    hosted: [{ path: path.join(directory, 'hosted.xcresult'), label: 'the hosted tests' }],
    ui: journeyRuns.map((run) => ({ path: path.join(directory, `journeys-${run.name}.xcresult`), label: `the journeys in ${run.label}` })),
  };
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

/** Puts the simulator in the setting, and every other setting back to its default. */
function apply(setting, simulator) {
  for (const command of settingCommands(setting, simulator)) simctl(command);
}

/**
 * The settings helper: an HTTP server on the Mac's loopback, at a free port, that a journey asks to put the
 * simulator in a setting. `POST /settings/<name>` applies the setting of that name with `applySetting`, and
 * answers 204 when it is applied. A name that is not a setting gets 404. The journey gets the helper's address in
 * its environment, because a test can't change text size or Increase Contrast from inside the simulator.
 *
 * Resolves with `{ address, close }`.
 */
export function startSettingsHelper(applySetting) {
  const server = createServer((request, response) => {
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
 * Builds the app and the test bundles, or finds them built by step 4, and runs the hosted tests and then the
 * journeys. The first run that fails ends it. Returns true when every run passed.
 */
export async function runSimulatorTier({ root, directory, say = console.log }) {
  rmSync(directory, { recursive: true, force: true });
  mkdirSync(directory, { recursive: true });
  const simulator = findOrMakeSimulator();
  const relative = (file) => path.relative(root, file);

  /** One `xcodebuild` run, with its line. `bundle` is the result bundle that the run writes, if it runs tests. */
  const run = async (what, args, { log, bundle, env }) => {
    const started = Date.now();
    const exit = await xcodebuild(args, { root, log: path.join(directory, log), env });
    const problem = bundle === undefined ? null : judge(readResultBundle(bundle));
    const ok = exit === 0 && problem === null;
    const why = problem ?? `xcodebuild ended with ${exit}`;
    say(ok ? `✓ ${what} (${duration(Date.now() - started)})` : `✗ ${what}: ${why} (log: ${relative(path.join(directory, log))})`);
    return ok;
  };

  // The simulator boots while the build runs. The build is for the simulator's kind of Mac, not for one device.
  const booted = new Promise((resolve, reject) => {
    const boot = spawn('xcrun', ['simctl', 'bootstatus', simulator, '-b'], { stdio: 'ignore' });
    boot.on('error', reject);
    boot.on('close', (code) => (code === 0 ? resolve() : reject(new Error(`simctl bootstatus ended with ${code}`))));
  });
  booted.catch(() => {});
  let helper = null;
  try {
    if (!(await run('Built the app and the test bundles for the simulator', buildArguments, { log: 'build.log' }))) return false;
    const testRun = findTestRun(path.join(root, 'build', 'DerivedData', 'Build', 'Products'));
    await booted;
    holdStatusBar(simulator);
    apply(settings[0], simulator);

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

    helper = await startSettingsHelper((setting) => apply(setting, simulator));
    for (const [index, journeys] of journeyRuns.entries()) {
      apply(settings[0], simulator);
      // xcodebuild gives the test runner each variable that starts with TEST_RUNNER_, without that start.
      const env = {
        TEST_RUNNER_WISHBONE_SETTINGS_HELPER: journeys.helper ? helper.address : '',
        TEST_RUNNER_WISHBONE_DOUBLE_LENGTH: journeys.doubleLength ? 'YES' : 'NO',
      };
      const bundle = bundles.ui[index].path;
      if (!(await run(`The journeys in ${journeys.label}`, test('JourneyTests', bundle), { log: `journeys-${journeys.name}.log`, bundle, env }))) return false;
    }
    return true;
  } finally {
    await helper?.close();
    try {
      apply(settings[0], simulator);
      simctl(['status_bar', simulator, 'clear']);
    } catch {
      // The simulator is gone. The next run starts it, and sets it again.
    }
    shutDownSimulator();
  }
}

if (import.meta.main) {
  const root = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8', cwd: path.dirname(fileURLToPath(import.meta.url)) }).trim();
  const directory = path.resolve(root, process.argv[2] ?? path.join('build', 'simulator'));
  try {
    // Under the gate, the gate holds the slot. By itself, the run takes it, so it never breaks another
    // checkout's gate on the one simulator.
    const passed = await inSlot(() => runSimulatorTier({ root, directory }), {
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
