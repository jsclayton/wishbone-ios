// The simulator tier: the hosted test bundle, then the journeys, on the gate's own simulator. `just simulator`
// runs it, and it is step 6 of the gate. See "The simulator tier" in docs/development.md.
//
// It builds as `just build` does, with the same arguments, and runs the tests from that build's `.xctestrun`
// file. Under the gate (`--no-build`), it doesn't build: step 5 is `just build`, so it runs step 5's build.
//
// The journeys run twice. In the first run, each screen that the journeys reach is audited in the four settings
// of the audit, once: the journey asks this script's settings helper, a small HTTP server on the Mac, whether a
// screen is new in the run, and to put the simulator in each setting with `simctl`. The second run is in the
// double-length pseudo-language, which needs a new launch.
//
// Every `xcodebuild` writes its log, and its result bundle, to the results folder. The script prints one line for
// each run. A run of the journeys that fails with the named flake "the app's launch gets no process ID on a busy
// machine" runs again, once (`runAgainOnLaunchFlake`).
//
// `--shard=<name>` runs one shard of the journeys (parts.mjs), as a job of the dispatched Gate run in CI does: only
// the shard's journeys, in both runs, and the hosted tests only when the shard has them.

import { execFile, execFileSync, spawn } from 'node:child_process';
import { closeSync, createWriteStream, existsSync, mkdirSync, openSync, readdirSync, readFileSync, readSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { createServer } from 'node:http';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import { duration } from './gate.mjs';
import { shardNamed } from './parts.mjs';
import { judge } from './reading.mjs';
import { inSlot, slotDirectory } from './slot.mjs';
import { checkAuditScreenshots, readAttachmentNames, readResultBundle } from './xcresult.mjs';

/** The name of the gate's own simulator. The gate makes it when the machine has none. */
export const simulatorName = 'Wishbone gate';

/** The status bar that the gate holds still: see `holdStatusBar`. */
const statusBarOverride = ['--time', '9:41', '--dataNetwork', 'wifi', '--wifiBars', '3', '--batteryState', 'charged', '--batteryLevel', '100'];

/** The device that the gate's simulator is, when the newest iOS has it. Otherwise it is that iOS's first iPhone. */
const preferredDevice = 'iPhone 18 Pro';

/**
 * The arguments of the one build of the app and its test bundles, for the simulator, in `xcodebuild`'s order.
 * `just build` (step 5 of the gate) builds with these, and so does this script, so the simulator step reuses
 * step 5's build. A gate test holds the justfile to them.
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
 * `just build` built, and `--shard=<name>` runs one shard of the journeys (parts.mjs). A word that starts with `--`
 * is a flag, never the folder. It gives `shard` only with `--shard`.
 */
export function parseArguments(args) {
  const known = ['--no-build', '--shard=<name>'];
  const flags = args.filter((arg) => arg.startsWith('--'));
  const words = args.filter((arg) => !arg.startsWith('--'));
  const unknown = flags.filter((flag) => flag !== '--no-build' && !flag.startsWith('--shard='));
  if (unknown.length > 0) throw new Error(`unknown flag ${unknown.join(', ')}. The flags are ${known.join(', ')}`);
  if (words.length > 1) throw new Error(`one results folder, not ${words.length}: ${words.join(', ')}`);
  const shards = flags.filter((flag) => flag.startsWith('--shard='));
  if (shards.length > 1) throw new Error(`one shard, not ${shards.length}`);
  const parsed = { results: words[0] ?? path.join('build', 'simulator'), build: !flags.includes('--no-build') };
  return shards.length === 0 ? parsed : { ...parsed, shard: shardNamed(shards[0].slice('--shard='.length)) };
}

/**
 * The result bundles of a run, for `checkResultBundles`: the hosted tests, and each run of the journeys. A shard
 * (parts.mjs) that doesn't run the hosted tests has no bundle of them.
 */
export function resultBundles(directory, shard) {
  const hosted = shard === undefined || shard.hosted === true;
  return {
    hosted: hosted ? [{ path: path.join(directory, 'hosted.xcresult'), label: 'the hosted tests' }] : [],
    ui: journeyRuns.map((run) => ({ path: path.join(directory, `journeys-${run.name}.xcresult`), label: `the journeys in ${run.label}` })),
  };
}

/** The `-only-testing:` arguments of a run of the journeys: every journey, or a shard's (parts.mjs). */
export function journeyTargets(shard) {
  return shard === undefined ? ['JourneyTests'] : shard.tests.map((test) => `JourneyTests/${test}`);
}

/**
 * The lines after a run of the journeys, with each journey's own time, the slowest first, so that the shards can be
 * cut again from what each journey takes. `times` maps a test's name to its time (`times` of a reading).
 */
export function journeyTimeLines(times) {
  return Object.entries(times ?? {})
    .sort(([one, oneMs], [other, otherMs]) => otherMs - oneMs || one.localeCompare(other))
    .map(([name, ms]) => `    ${name}: ${duration(ms)}`);
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
 * The time that each of the two changes of a change sent again may take (see `startSettingsHelper`). With the
 * read of the three options before them, they fit in `helperAnswerLimitMs`, so the journey still gets the helper's
 * own error. A call can hang once, be read back, and run again, in it.
 */
export const resendAnswerLimitMs = (helperAnswerLimitMs - 3 * settingReadLimitMs) / 2;

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
 * The simulator's CoreSimulatorBridge, as its launchd knows it. It is a daemon inside the simulator, and it answers
 * each `simctl ui` call, and `simctl status_bar`, for the Mac. Its launchd keeps it alive, so a restart starts it
 * again at once.
 */
export const bridgeService = 'user/foreground/com.apple.CoreSimulator.bridge';

/** The limit of each call of a recovery (`bridgeRecovery`). */
const recoveryCallLimitsMs = { print: 10_000, ps: 5_000, sample: 10_000, restart: 10_000, hold: 10_000 };

/** The longest time that a recovery takes: its calls' limits, added up. */
export const recoveryLimitMs = Object.values(recoveryCallLimitsMs).reduce((sum, one) => sum + one, 0);

/** The words of an error, on one line, with no full stop at the end. */
function errorWords(error) {
  return String(error.message ?? error).trim().split('\n')[0].replace(/\.$/, '');
}

/** The first three lines of a sample's "Sort by top of stack", as `<function> <count>`. */
function topOfStack(sample) {
  const lines = sample.split('\n');
  const start = lines.findIndex((line) => line.startsWith('Sort by top of stack'));
  if (start === -1) return 'not in the sample';
  const top = [];
  for (const line of lines.slice(start + 1)) {
    if (line.trim() === '' || top.length === 3) break;
    const match = line.match(/^\s*(.+?)\s+\(in [^)]*\)\s+(\d+)\s*$/);
    top.push(match === null ? line.trim() : `${match[1]} ${match[2]}`);
  }
  return top.join(', ');
}

/**
 * The recovery from a hung `simctl ui` call, for `settingsApplier`: the named flake "a `simctl ui` call hangs on a
 * CI runner" in docs/development.md. A call of `simctl ui` waits for the simulator's CoreSimulatorBridge to answer.
 * A bridge that is stopped (SIGSTOP) makes every `simctl ui` call, a change or a read, hang until its limit, which
 * is the flake's signature. A restart of the bridge ends that at once, and drops the status bar's override.
 *
 * So the recovery first records what the bridge was doing: its state in launchd, its process's state and CPU on the
 * Mac (`ps`), and a sample of it for a second, whose file it keeps in `directory`. Then it restarts the bridge
 * (`launchctl kickstart -k`), and holds the status bar again. Each step has its own limit, and a step that fails
 * doesn't stop the ones after it. It resolves with one line that says what it found and did.
 *
 * `run(args, limitMs)` is a `simctl` call, and `host(file, args, limitMs)` a call of a program on the Mac, both with
 * a limit, as `simctlWithLimit`. `relative(file)` gives a file's name for the line.
 */
export function bridgeRecovery(
  simulator,
  {
    directory,
    run = simctlWithLimit,
    host = (file, args, limitMs) => simctlWithLimit(args, limitMs, { file, prefix: [] }),
    relative = (file) => file,
  },
) {
  let count = 0;
  return async () => {
    count += 1;
    const limits = recoveryCallLimitsMs;
    let found;
    try {
      const print = await run(['spawn', simulator, 'launchctl', 'print', bridgeService], limits.print);
      const field = (name) => print.match(new RegExp(`^\\t${name} = (.+)$`, 'm'))?.[1].trim() ?? null;
      const pid = field('pid');
      found = `CoreSimulatorBridge was ${pid === null ? 'not running' : `pid ${pid}`}, launchd state ${field('state') ?? 'unknown'}, run ${field('runs') ?? 'unknown'}`;
      if (pid !== null) {
        try {
          const [stat, cpu, up] = (await host('ps', ['-o', 'stat=,%cpu=,etime=', '-p', pid], limits.ps)).trim().split(/\s+/);
          found += `, ps ${stat} ${cpu}% CPU up ${up}`;
        } catch (error) {
          found += `, ps couldn't read it: ${errorWords(error)}`;
        }
        const file = path.join(directory, `bridge-${count}.txt`);
        try {
          await host('sample', [pid, '1', '-file', file], limits.sample);
          found += `; top of its stack: ${topOfStack(readFileSync(file, 'utf8'))} (sample: ${relative(file)})`;
        } catch (error) {
          found += `; couldn't sample it: ${errorWords(error)}`;
        }
      }
      found += '.';
    } catch (error) {
      found = `Couldn't read CoreSimulatorBridge's state: ${errorWords(error)}.`;
    }
    let restarted = null;
    try {
      await run(['spawn', simulator, 'launchctl', 'kickstart', '-k', bridgeService], limits.restart);
    } catch (error) {
      restarted = errorWords(error);
    }
    let held = null;
    try {
      await run(['status_bar', simulator, 'override', ...statusBarOverride], limits.hold);
    } catch (error) {
      held = errorWords(error);
    }
    if (restarted === null && held === null) return `${found} Restarted it, and held the status bar again.`;
    if (restarted === null) return `${found} Restarted it, but couldn't hold the status bar again: ${held}.`;
    if (held === null) return `${found} Couldn't restart it: ${restarted}. Held the status bar again.`;
    return `${found} Couldn't restart it: ${restarted}, or hold the status bar again: ${held}.`;
  };
}

/** The lines after the journeys in the four settings, for each recovery of a hung call (`bridgeRecovery`). */
export function bridgeRecoveryLines(recoveries) {
  if (recoveries.length === 0) return [];
  return [
    "  After each hang, the helper looked at the simulator's CoreSimulatorBridge, which answers `simctl ui`, and restarted it:",
    ...recoveries.map((line) => `    ${line}`),
  ];
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
 * After a hang, and before the wait, the applier runs `recover()`, when it was given one and the change has
 * `recoveryLimitMs` left: `bridgeRecovery` records what the simulator's CoreSimulatorBridge, which answers
 * `simctl ui`, was doing, and restarts it. `recover` resolves with a line that says what it found and did. The
 * applier keeps each line, after the call that hung. A recovery that fails doesn't fail the change: its line says
 * why.
 *
 * `apply` takes `{ limitMs, answerLimitMs }`, which are `limitMs` and `answerLimitMs` unless it says otherwise.
 *
 * It applies one setting at a time: an `apply` that comes while another runs waits for it, also when that one
 * fails. So a journey whose request timed out leaves no call running beside the next journey's.
 *
 * `now` and `sleep` are the clock, so a test runs it on its own clock.
 *
 * `read()` reads each option of the settings back from the simulator, in the same queue, and resolves with them in
 * words, such as `appearance light, increase_contrast disabled, content_size large`. An option that it can't read
 * is `<option> unread`. The helper reads them when a journey sends a change again (`startSettingsHelper`), so the
 * gate's line says whether the simulator had the setting that the app didn't show.
 *
 * Returns `{ apply(setting, { limitMs, answerLimitMs }), read(), calls(), hangs(), ms(), recoveries() }`: the
 * number of calls that changed a setting, how many of them hung, the time that the changes took, and the line of
 * each recovery, in the order they ran.
 */
export function settingsApplier(
  simulator,
  {
    run = simctlWithLimit,
    limitMs = settingCallLimitMs,
    answerLimitMs = helperAnswerLimitMs,
    readLimitMs = settingReadLimitMs,
    pauseMs = settingPauseMs,
    recover = null,
    now = Date.now,
    sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  } = {},
) {
  const set = new Map();
  let calls = 0;
  let hangs = 0;
  let ms = 0;
  const recoveries = [];
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
          if (recover !== null && fits(recoveryLimitMs)) {
            let found;
            try {
              found = await recover();
            } catch (error) {
              found = `the recovery failed: ${error.message}`;
            }
            recoveries.push(`simctl ${command.join(' ')}: ${found}`);
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
    read() {
      const read = queue.then(async () => {
        const values = [];
        for (const command of settingCommands(settings[0], simulator)) {
          const [, , name] = command;
          try {
            values.push(`${name} ${(await run(command.slice(0, 3), readLimitMs)).trim()}`);
          } catch {
            values.push(`${name} unread`);
          }
        }
        return values.join(', ');
      });
      queue = read.catch(() => {});
      return read;
    },
    calls: () => calls,
    hangs: () => hangs,
    ms: () => ms,
    recoveries: () => [...recoveries],
  };
}

/**
 * The settings helper: an HTTP server on the Mac's loopback, at a free port, that a journey asks to put the
 * simulator in a setting. `POST /settings/<name>` applies the setting of that name with `applySetting`, and
 * answers 204 when it is applied. A name that is not a setting gets 404. The journey gets the helper's address in
 * its environment, because a test can't change text size or Increase Contrast from inside the simulator.
 *
 * `POST /settings/<name>?after=<previous>` sends a change again: the named flake "a change of setting doesn't show
 * in the app" in docs/development.md, where `simctl` applied the change but the app went on showing the screen as it
 * was. The helper reads the settings back with `readSettings`, then applies `previous` and then the setting, so each
 * option of the change is set once more. The read and the two changes share the helper's answer limit:
 * `applySetting(setting, options)` gets `{ answerLimitMs: resendAnswerLimitMs }` for each. It remembers each change
 * that it sent again, with what it read.
 *
 * It also knows which screens the run has audited. `POST /screens`, with a screen's name as the body, answers
 * 201 when the name is new in the run, so the journey audits the screen, and 200 when a journey audited it
 * already, so the journey doesn't audit it again. Only the run in the four settings has a helper, and it starts
 * its own, so the screens that it remembers are that run's.
 *
 * `POST /audit-retries`, with the audit's screen and setting as the body, records that an audit ran again after
 * XCTest said that it didn't complete in time: the named flake "an accessibility audit doesn't complete in time on
 * a CI runner" in docs/development.md. It answers 204. `POST /screenshot-retries`, with the screen and setting as
 * the body, records the same for a screenshot that XCTest didn't get in time: the named flake "XCTest doesn't get a
 * screenshot on a CI runner". `POST /lost-element-retries`, the same way, records an audit that ran again because an
 * issue that no exception allows had no element: the named flake "an audit's issue has no element".
 * `POST /partly-scaling-retries`, the same way, records an audit that ran again because every issue that no
 * exception allows was text that the Dynamic Type check called partially unsupported: the named flake "the Dynamic
 * Type check calls text that scales partially unsupported".
 *
 * Resolves with `{ address, close, screens, resends, auditRetries, screenshotRetries, lostElementRetries,
 * partlyScalingRetries }`, where `screens()` gives the names, in the
 * order they came, `resends()` gives each change that a journey sent again: `{ setting, after, read }`, with the
 * settings' labels and what `readSettings` read before the change was sent again, and `auditRetries()` gives each
 * audit that ran again, by its screen and setting, in the order they came. `screenshotRetries()` gives each
 * screenshot that was asked for again, the same way, `lostElementRetries()` each audit that ran again for an
 * issue with no element, and `partlyScalingRetries()` each audit that ran again for text called partially
 * unsupported.
 */
export function startSettingsHelper(applySetting, { readSettings = async () => 'not read' } = {}) {
  const resends = [];
  const auditRetries = [];
  const screenshotRetries = [];
  const lostElementRetries = [];
  const partlyScalingRetries = [];
  const retries = {
    '/audit-retries': [auditRetries, 'audit'],
    '/screenshot-retries': [screenshotRetries, 'screenshot'],
    '/lost-element-retries': [lostElementRetries, 'audit'],
    '/partly-scaling-retries': [partlyScalingRetries, 'audit'],
  };
  const screens = new Set();
  const server = createServer((request, response) => {
    if (Object.hasOwn(retries, request.url ?? '')) {
      const [list, what] = retries[request.url];
      if (request.method !== 'POST') {
        response.writeHead(404).end();
        return;
      }
      const body = [];
      request.on('data', (chunk) => body.push(chunk));
      request.on('end', () => {
        const retried = Buffer.concat(body).toString('utf8');
        if (retried === '') {
          response.writeHead(400, { 'Content-Type': 'text/plain' }).end(`the ${what}'s screen and setting, as the body`);
          return;
        }
        list.push(retried);
        response.writeHead(204).end();
      });
      return;
    }
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
    const url = new URL(request.url ?? '/', 'http://helper');
    const match = /^\/settings\/([a-z-]+)$/.exec(url.pathname);
    const setting = settings.find((one) => one.name === match?.[1]);
    const afterName = url.searchParams.get('after');
    const after = afterName === null ? null : settings.find((one) => one.name === afterName);
    if (request.method !== 'POST' || setting === undefined || after === undefined || after === setting) {
      response.writeHead(404).end();
      return;
    }
    Promise.resolve()
      .then(async () => {
        if (after === null) {
          await applySetting(setting);
          return;
        }
        const answerLimitMs = resendAnswerLimitMs;
        resends.push({ setting: setting.label, after: after.label, read: await readSettings() });
        await applySetting(after, { answerLimitMs });
        await applySetting(setting, { answerLimitMs });
      })
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
        resends: () => resends.map((one) => ({ ...one })),
        auditRetries: () => [...auditRetries],
        screenshotRetries: () => [...screenshotRetries],
        lostElementRetries: () => [...lostElementRetries],
        partlyScalingRetries: () => [...partlyScalingRetries],
      });
    });
  });
}

/** The name of the flake that a journey meets by sending a change again. See `startSettingsHelper`. */
export const resendFlake = "a change of setting doesn't show in the app";

/** The name of the flake that a journey meets by running an audit again. See `startSettingsHelper`. */
export const auditTimeOutFlake = "an accessibility audit doesn't complete in time on a CI runner";

/** The name of the flake that a journey meets by running an audit again for an issue with no element. */
export const lostElementFlake = "an audit's issue has no element";

/**
 * The lines after a run of the journeys, one for each audit that ran again because an issue that no exception allows
 * had no element (`lostElementRetries()` of `startSettingsHelper`). None when no audit ran again for that.
 */
export function lostElementRetryLines(retries) {
  if (retries.length === 0) return [];
  const audits = retries.length === 1 ? '1 audit' : `${retries.length} audits`;
  return [
    `  The journeys ran ${audits} again, because an issue had no element (the named flake "${lostElementFlake}"):`,
    ...retries.map((audit) => `    ${audit}.`),
  ];
}

/** The name of the flake that a journey meets by running an audit again for text called partially unsupported. */
export const partlyScalingFlake = 'the Dynamic Type check calls text that scales partially unsupported';

/**
 * The lines after a run of the journeys, one for each audit that ran again because every issue that no exception
 * allows was text that the Dynamic Type check called partially unsupported (`partlyScalingRetries()` of
 * `startSettingsHelper`). None when no audit ran again for that.
 */
export function partlyScalingRetryLines(retries) {
  if (retries.length === 0) return [];
  const audits = retries.length === 1 ? '1 audit' : `${retries.length} audits`;
  return [
    `  The journeys ran ${audits} again, because the Dynamic Type check called text partially unsupported (the named flake "${partlyScalingFlake}"):`,
    ...retries.map((audit) => `    ${audit}.`),
  ];
}

/** The name of the flake that a journey meets by asking for a screenshot again. See `startSettingsHelper`. */
export const screenshotTimeOutFlake = "XCTest doesn't get a screenshot on a CI runner";

/**
 * The lines after a run of the journeys, one for each screenshot that a journey asked for again because XCTest
 * didn't get it in time (`screenshotRetries()` of `startSettingsHelper`). None when no screenshot was asked again.
 */
export function screenshotRetryLines(retries) {
  if (retries.length === 0) return [];
  const screenshots = retries.length === 1 ? '1 screenshot' : `${retries.length} screenshots`;
  return [
    `  The journeys asked for ${screenshots} again, because XCTest didn't get it in time (the named flake "${screenshotTimeOutFlake}"):`,
    ...retries.map((shown) => `    ${shown}.`),
  ];
}

/**
 * The lines after a run of the journeys, one for each audit that ran again because XCTest said that it didn't
 * complete in time (`auditRetries()` of `startSettingsHelper`). None when no audit ran again.
 */
export function auditRetryLines(retries) {
  if (retries.length === 0) return [];
  const audits = retries.length === 1 ? '1 audit' : `${retries.length} audits`;
  return [
    `  The journeys ran ${audits} again, because XCTest said that it didn't complete in time (the named flake "${auditTimeOutFlake}"):`,
    ...retries.map((audit) => `    ${audit}.`),
  ];
}

/**
 * The lines after a run of the journeys, one for each change that a journey sent again (`resends()` of
 * `startSettingsHelper`), with what the simulator read before it. None when no change was sent again.
 */
export function resendLines(resends) {
  if (resends.length === 0) return [];
  const changes = resends.length === 1 ? '1 change' : `${resends.length} changes`;
  return [
    `  The journeys sent ${changes} of setting again, because the app went on showing the screen as it was (the named flake "${resendFlake}"):`,
    ...resends.map(({ setting, after, read }) => `    ${after} to ${setting}. The simulator read: ${read}.`),
  ];
}

/**
 * A screenshot shows the status bar, and its clock moves. The journey waits for the screen to show a setting by
 * comparing screenshots, so the clock and the rest of the bar are held still.
 */
function holdStatusBar(simulator) {
  simctl(['status_bar', simulator, 'override', ...statusBarOverride]);
}

/**
 * The named flake "the gate's simulator shuts down by itself at the step's start" in docs/development.md. On CI,
 * the simulator booted and its status bar was held, and then the first call that put it in the default settings
 * found it shut down.
 */
export const shutdownFlake = "the gate's simulator shuts down by itself at the step's start";

/** How many times the step's start boots the simulator again after it shut down by itself. */
export const startReboots = 2;

/** Whether a `simctl` call failed because the simulator was shut down: CoreSimulator's error 405 says so. */
export function shutDownBySelf(error) {
  return /in current state: Shutdown\b/.test(error?.message ?? '');
}

/** The most of each log that `keepStartLogs` keeps: the end of it, where the shutdown is. */
export const startLogLimitBytes = 2 * 1024 * 1024;

/** The end of a file, at most `limitBytes`, or null when the file isn't there. */
function endOf(file, limitBytes) {
  if (!existsSync(file)) return null;
  const size = statSync(file).size;
  const length = Math.min(size, limitBytes);
  const buffer = Buffer.alloc(length);
  const handle = openSync(file, 'r');
  try {
    readSync(handle, buffer, 0, length, size - length);
  } finally {
    closeSync(handle);
  }
  return buffer.toString('utf8');
}

/**
 * Keeps the end of CoreSimulator's own log and of the simulator's system log, after the simulator shut down by
 * itself, in `<directory>/simulator-start-<sighting>-first.log`. The name ends in `-first.log`, so CI uploads it
 * after a pass too, as it does a first try of the journeys. So the next sighting can say why it shut down. Returns
 * the file's path.
 */
export function keepStartLogs({ directory, simulator, sighting, logs = path.join(homedir(), 'Library', 'Logs', 'CoreSimulator'), limitBytes = startLogLimitBytes }) {
  const parts = [path.join(logs, 'CoreSimulator.log'), path.join(logs, simulator, 'system.log')].map((file) => {
    const text = endOf(file, limitBytes);
    const name = path.relative(logs, file);
    return text === null ? `── ${name}: not there\n` : `── ${name}: its last ${text.length} characters\n${text}\n`;
  });
  const kept = path.join(directory, `simulator-start-${sighting}-first.log`);
  writeFileSync(kept, parts.join('\n'));
  return kept;
}

/**
 * The step's start: `boot()`, `hold()` the status bar still, and `putInDefault()`, which resolves with the
 * `settingsApplier` that it used. A line for each part, with its time. When a call of the start finds the
 * simulator shut down (`shutDownBySelf`), the start keeps its logs (`keepLogs(sighting)`, which returns where), and
 * runs again from the boot, at most `startReboots` times. Any other failure, and a shutdown after that, is red.
 * Resolves with the applier.
 */
export async function startSimulator({ boot, hold, putInDefault, keepLogs, say = console.log, reboots = startReboots }) {
  const timed = async (what, work) => {
    const started = Date.now();
    const result = await work();
    say(`✓ ${what} (${duration(Date.now() - started)})`);
    return result;
  };
  for (let sighting = 1; ; sighting += 1) {
    const again = sighting === 1 ? '' : ' again';
    try {
      await timed(`Booted the gate's simulator${again}`, boot);
      await timed(`Held the simulator's status bar still${again}`, hold);
      return await timed(`Put the simulator in the default settings${again}`, putInDefault);
    } catch (error) {
      if (!shutDownBySelf(error)) throw error;
      const kept = keepLogs(sighting);
      if (sighting > reboots) {
        say(`  The simulator shut down by itself at the step's start, ${sighting} times (the named flake "${shutdownFlake}"). Its logs are in ${kept}.`);
        throw error;
      }
      const message = error.message.replace(/\s+/g, ' ');
      say(`  The simulator shut down by itself at the step's start (the named flake "${shutdownFlake}"), so it boots again (${sighting} of ${reboots}). The call: ${message}. Its logs are in ${kept}.`);
    }
  }
}

/**
 * Boots the gate's simulator, holds its status bar still, and puts it in the default settings, with a line for
 * each part and its time (`startSimulator`). The simulator's logs at a shutdown go in `directory`. Returns
 * `{ simulator, applier }`: the simulator's ID, and the `settingsApplier` that knows its settings.
 */
export async function prepareSimulator({ directory, say = console.log, relative = (file) => file }) {
  const started = Date.now();
  const simulator = findOrMakeSimulator();
  say(`✓ Found the gate's simulator (${duration(Date.now() - started)})`);
  // One recovery for every applier of the step, so that each sample has a name of its own.
  const recover = bridgeRecovery(simulator, { directory, relative });
  const applier = await startSimulator({
    boot: () => simctl(['bootstatus', simulator, '-b'], { stdio: 'ignore' }),
    hold: () => holdStatusBar(simulator),
    // A new applier each time: it runs every call, because the simulator that booted again can be in any setting.
    putInDefault: async () => {
      const one = settingsApplier(simulator, { recover });
      await one.apply(settings[0], { limitMs: readinessCallLimitMs, answerLimitMs: readinessAnswerLimitMs });
      return one;
    },
    keepLogs: (sighting) => relative(keepStartLogs({ directory, simulator, sighting })),
    say,
  });
  return { simulator, applier };
}

/**
 * The named flake "the app's launch gets no process ID on a busy machine" in docs/development.md. On a machine
 * under very high load, XCTest's `launch()` gives up before the app is ready, at one of two of its steps. First
 * it waits for the app's process, and it can fail with "Application '<bundle ID>' does not have a process ID".
 * After the app's first activation, when the test runner's environment has LLVM_PROFILE_FILE (code coverage on),
 * it asks for a background assertion for the app's process, and it can fail with "Failed to get background
 * assertion for target app with pid <pid>". Both are in XCUIAutomation's
 * `-[XCUIApplicationImpl _launchWithRequest:]`, before it waits for the app's accessibility and for the app to go
 * idle. On CI, the test runner then failed too, and Xcode reports that as a test of its own, named
 * "<runner> (<pid>) encountered an error".
 */
export const launchFlake = {
  name: "the app's launch gets no process ID on a busy machine",
  message: /Application '[^']+' does not have a process ID|Failed to get background assertion for target app with pid \d+/,
  runner: /-Runner \(\d+\) encountered an error$/,
};

/**
 * Whether a reading of a run of the journeys failed with the launch flake's signature, and nothing else: at least
 * one test failed, and each of its failure messages is a launch that `launch()` gave up on, and every other failure
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
  say(`  ${launches.join(', ')}: XCTest gave up on the launch (the named flake "${launchFlake.name}"), so this run of the journeys runs again, once. The first run is in ${kept.join(' and ')}.`);
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
 * its step 5 has just built them. On CI, a build next to a newly booted simulator took minutes, even with nothing
 * to compile.
 */
export async function runSimulatorTier({ root, directory, build = true, shard, say = console.log }) {
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
    ({ simulator, applier } = await prepareSimulator({ directory, say, relative }));
    if (build) {
      if (!(await run('Built the app and the test bundles for the simulator', buildArguments, { log: 'build.log' }))) return false;
      // After `just build`, the build has nothing to compile. The line says so.
      say(`  It compiled ${compiledFiles(path.join(directory, 'build.log'))} Swift files.`);
    }
    const testRun = findTestRun(path.join(root, 'build', 'DerivedData', 'Build', 'Products'));
    if (!build) say(`✓ Took the app and the test bundles from the gate's build step (${relative(testRun)})`);

    const bundles = resultBundles(directory, shard);
    const test = (only, bundle) => [
      'test-without-building',
      '-xctestrun',
      testRun,
      '-destination',
      `platform=iOS Simulator,id=${simulator}`,
      ...only.map((target) => `-only-testing:${target}`),
      '-resultBundlePath',
      bundle,
      '-parallel-testing-enabled',
      'NO',
    ];
    if (shard !== undefined) say(`  The shard ${shard.name}: ${shard.tests.length} journeys${bundles.hosted.length > 0 ? ', and the hosted tests' : ''}.`);
    for (const hosted of bundles.hosted) {
      if (!(await run('The hosted tests', test(['HostedTests'], hosted.path), { log: 'hosted.log', bundle: hosted.path }))) return false;
    }

    for (const [index, journeys] of journeyRuns.entries()) {
      const bundle = bundles.ui[index].path;
      const log = `journeys-${journeys.name}.log`;
      /** One run of these journeys, with a new helper. Resolves with whether it passed, and its reading. */
      const runJourneys = async () => {
        await applier.apply(settings[0]);
        const helperCalls = applier.calls();
        const helperHangs = applier.hangs();
        const helperMs = applier.ms();
        const helperRecoveries = applier.recoveries().length;
        // Only the run in the four settings has a helper, so the screens that it remembers are that run's.
        await helper?.close();
        helper = journeys.helper ? await startSettingsHelper((setting, options) => applier.apply(setting, options), { readSettings: () => applier.read() }) : null;
        // xcodebuild gives the test runner each variable that starts with TEST_RUNNER_, without that start.
        const env = {
          TEST_RUNNER_WISHBONE_SETTINGS_HELPER: helper?.address ?? '',
          TEST_RUNNER_WISHBONE_DOUBLE_LENGTH: journeys.doubleLength ? 'YES' : 'NO',
        };
        let reading = null;
        const passed = await run(`The journeys in ${journeys.label}`, test(journeyTargets(shard), bundle), { log, bundle, env, onReading: (one) => (reading = one) });
        for (const line of journeyTimeLines(reading?.times)) say(line);
        if (journeys.helper) {
          const hung = applier.hangs() - helperHangs;
          const again = hung === 0 ? '' : `, and ${hung} of them hung (the named flake "a \`simctl ui\` call hangs on a CI runner")`;
          say(`  The settings helper made ${applier.calls() - helperCalls} simctl calls, in ${duration(applier.ms() - helperMs)}${again}.`);
          for (const line of bridgeRecoveryLines(applier.recoveries().slice(helperRecoveries))) say(line);
          for (const line of resendLines(helper.resends())) say(line);
          for (const line of auditRetryLines(helper.auditRetries())) say(line);
          for (const line of screenshotRetryLines(helper.screenshotRetries())) say(line);
          for (const line of lostElementRetryLines(helper.lostElementRetries())) say(line);
          for (const line of partlyScalingRetryLines(helper.partlyScalingRetries())) say(line);
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
    const { results, build, shard } = parseArguments(process.argv.slice(2));
    const directory = path.resolve(root, results);
    // Under the gate, the gate holds the slot. By itself, the run takes it, so it never breaks another
    // checkout's gate on the one simulator.
    const passed = await inSlot(() => runSimulatorTier({ root, directory, build, shard }), {
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
