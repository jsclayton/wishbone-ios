// The simulator tier: the hosted test bundle, then the journeys, one at a time, on the gate's own simulator.
// `just simulator` runs it, and it is step 5 of the gate. See "The simulator tier" in docs/development.md.
//
// The journeys run once in each setting of `settings`. A journey can't change the simulator's settings from
// inside the simulator, so this script changes them between the runs, with `simctl`.
//
// Every `xcodebuild` writes its log, and its result bundle, to the results folder. The script prints one line for
// each run.

import { execFileSync, spawn } from 'node:child_process';
import { createWriteStream, mkdirSync, rmSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import { duration } from './gate.mjs';
import { judge } from './reading.mjs';
import { readResultBundle } from './xcresult.mjs';

/** The name of the gate's own simulator. The gate makes it when the machine has none. */
export const simulatorName = 'Wishbone gate';

/** The device that the gate's simulator is, when the newest iOS has it. Otherwise it is that iOS's first iPhone. */
const preferredDevice = 'iPhone 18 Pro';

/**
 * The settings that the journeys run in, with their accessibility audit: the default, the largest accessibility
 * text size, dark mode, and Increase Contrast. The last run is in the double-length pseudo-language, which shows
 * text that is cut short, and text that is not in the String Catalog.
 */
export const settings = [
  { name: 'default', label: 'the default settings' },
  { name: 'largest-text', label: 'the largest text size', contentSize: 'accessibility-extra-extra-extra-large' },
  { name: 'dark-mode', label: 'dark mode', appearance: 'dark' },
  { name: 'increase-contrast', label: 'Increase Contrast', increaseContrast: 'enabled' },
  { name: 'double-length', label: 'the double-length pseudo-language', doubleLength: true },
];

/** The result bundles of a run, for `checkResultBundles`: the hosted tests, and the journeys in each setting. */
export function resultBundles(directory) {
  return {
    hosted: [{ path: path.join(directory, 'hosted.xcresult'), label: 'the hosted tests' }],
    ui: settings.map((setting) => ({ path: path.join(directory, `journeys-${setting.name}.xcresult`), label: `the journeys in ${setting.label}` })),
  };
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

/** Puts the simulator in the setting, and every other setting back to its default. */
function apply(setting, simulator) {
  simctl(['ui', simulator, 'appearance', setting.appearance ?? 'light']);
  simctl(['ui', simulator, 'increase_contrast', setting.increaseContrast ?? 'disabled']);
  simctl(['ui', simulator, 'content_size', setting.contentSize ?? 'large']);
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
 * Builds the app and the test bundles, and runs the hosted tests and then the journeys in each setting. The
 * first run that fails ends it. Returns true when every run passed.
 */
export async function runSimulatorTier({ root, directory, say = console.log }) {
  rmSync(directory, { recursive: true, force: true });
  mkdirSync(directory, { recursive: true });
  const simulator = findOrMakeSimulator();
  const shared = ['-project', 'Wishbone.xcodeproj', '-scheme', 'Wishbone', '-destination', `platform=iOS Simulator,id=${simulator}`, '-derivedDataPath', 'build/DerivedData'];
  const relative = (file) => path.relative(root, file);

  /** One `xcodebuild` run, with its line. `bundle` is the result bundle that the run writes, if it runs tests. */
  const run = async (what, args, { log, bundle, env }) => {
    const started = Date.now();
    const exit = await xcodebuild([...args, ...shared], { root, log: path.join(directory, log), env });
    const problem = bundle === undefined ? null : judge(readResultBundle(bundle));
    const ok = exit === 0 && problem === null;
    const why = problem ?? `xcodebuild ended with ${exit}`;
    say(ok ? `✓ ${what} (${duration(Date.now() - started)})` : `✗ ${what}: ${why} (log: ${relative(path.join(directory, log))})`);
    return ok;
  };

  try {
    simctl(['bootstatus', simulator, '-b'], { stdio: 'ignore' });
    if (!(await run('Built the app and the test bundles for the simulator', ['build-for-testing', '-configuration', 'Debug'], { log: 'build.log' }))) return false;

    const bundles = resultBundles(directory);
    const test = (only, bundle) => ['test-without-building', `-only-testing:${only}`, '-resultBundlePath', bundle, '-parallel-testing-enabled', 'NO'];
    apply(settings[0], simulator);
    if (!(await run('The hosted tests', test('HostedTests', bundles.hosted[0].path), { log: 'hosted.log', bundle: bundles.hosted[0].path }))) return false;

    for (const [index, setting] of settings.entries()) {
      apply(setting, simulator);
      // xcodebuild gives the test runner each variable that starts with TEST_RUNNER_, without that start.
      const env = { TEST_RUNNER_WISHBONE_AUDIT_SETTING: setting.label, TEST_RUNNER_WISHBONE_DOUBLE_LENGTH: setting.doubleLength ? 'YES' : 'NO' };
      const bundle = bundles.ui[index].path;
      if (!(await run(`The journeys in ${setting.label}`, test('JourneyTests', bundle), { log: `journeys-${setting.name}.log`, bundle, env }))) return false;
    }
    return true;
  } finally {
    try {
      apply(settings[0], simulator);
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
    process.exit((await runSimulatorTier({ root, directory })) ? 0 : 1);
  } catch (error) {
    console.error(`✗ The simulator tests: ${error.message}`);
    process.exit(1);
  }
}
