import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

import { testResults } from './xcresult-fixture.mjs';
import { readTestResults } from './xcresult.mjs';

import {
  auditRetryLines,
  auditTimeOutFlake,
  lostElementFlake,
  lostElementRetryLines,
  partlyScalingFlake,
  partlyScalingRetryLines,
  buildArguments,
  compiledFiles,
  gateSimulators,
  hangFlake,
  hangFlakeIn,
  hangRecord,
  hangRecordLines,
  helperAnswerLimitMs,
  journeyRuns,
  keepFirstTry,
  keepStartLogs,
  launchFlake,
  launchFlakeIn,
  parseArguments,
  pickDevice,
  readinessAnswerLimitMs,
  readinessCallLimitMs,
  recordLimitMs,
  resendAnswerLimitMs,
  resendFlake,
  resendLines,
  resultBundles,
  runWithLimit,
  runAgainOnFlake,
  screenshotRetryLines,
  screenshotTimeOutFlake,
  settingCallLimitMs,
  settingPauseMs,
  settingReadLimitMs,
  settingCommands,
  settings,
  settingsApplier,
  shutDownBySelf,
  shutdownFlake,
  simctlWithLimit,
  startReboots,
  startSettingsHelper,
  startSimulator,
} from './simulator.mjs';

const iPhone = (name) => ({ name, identifier: `type.${name.replaceAll(' ', '-')}`, productFamily: 'iPhone' });
const iPad = (name) => ({ name, identifier: `type.${name.replaceAll(' ', '-')}`, productFamily: 'iPad' });
const runtime = (version, types, more = {}) => ({ identifier: `runtime.iOS-${version}`, version, platform: 'iOS', isAvailable: true, supportedDeviceTypes: types, ...more });

test('a new simulator is the preferred iPhone, on the newest iOS that has it', () => {
  const runtimes = [
    runtime('27.0', [iPhone('iPhone 18 Pro'), iPhone('iPhone 17')]),
    runtime('27.10', [iPad('iPad mini'), iPhone('iPhone 17'), iPhone('iPhone 18 Pro')]),
    runtime('27.2', [iPhone('iPhone 18 Pro')]),
  ];
  assert.deepEqual(pickDevice(runtimes), { runtime: 'runtime.iOS-27.10', deviceType: 'type.iPhone-18-Pro' });
});

test('a runtime that has only another iPhone loses to an older one with the preferred iPhone', () => {
  const runtimes = [runtime('27.2', [iPhone('iPhone Duo')], { identifier: 'runtime.duo' }), runtime('27.1', [iPhone('iPhone 18 Pro')])];
  assert.deepEqual(pickDevice(runtimes), { runtime: 'runtime.iOS-27.1', deviceType: 'type.iPhone-18-Pro' });
});

test('with no preferred iPhone anywhere, a new simulator is the first iPhone of the newest iOS', () => {
  const runtimes = [runtime('27.0', [iPhone('iPhone 17')]), runtime('28.0', [iPad('iPad mini'), iPhone('iPhone 19'), iPhone('iPhone 19 Pro')])];
  assert.deepEqual(pickDevice(runtimes), { runtime: 'runtime.iOS-28.0', deviceType: 'type.iPhone-19' });
});

test('a runtime that is not available, not iOS, or has no iPhone is never picked', () => {
  const runtimes = [
    runtime('28.0', [iPhone('iPhone 18 Pro')], { isAvailable: false }),
    runtime('28.0', [iPhone('iPhone 18 Pro')], { platform: 'tvOS' }),
    runtime('28.0', [iPad('iPad mini')]),
  ];
  assert.equal(pickDevice(runtimes), null);
  assert.equal(pickDevice([]), null);
  assert.equal(pickDevice(undefined), null);
});

test("the gate's simulators are the ones with its name, on any iOS", () => {
  const devices = {
    'runtime.iOS-27.0': [{ name: 'iPhone 18 Pro', udid: 'A' }, { name: 'Wishbone gate', udid: 'B', state: 'Shutdown', isAvailable: false }],
    'runtime.iOS-27.2': [{ name: 'Wishbone gate', udid: 'C', state: 'Booted', isAvailable: true }],
  };
  assert.deepEqual(gateSimulators(devices).map((device) => device.udid), ['B', 'C']);
  assert.deepEqual(gateSimulators({}), []);
});

test('the audit has four settings, and the first is the default of each', () => {
  assert.deepEqual(settings.map((setting) => setting.name), ['default', 'largest-text', 'dark-mode', 'increase-contrast']);
  // Applying the first setting puts the simulator back.
  assert.deepEqual(Object.keys(settings[0]), ['name', 'label']);
  assert.deepEqual(settingCommands(settings[0], 'SIM'), [
    ['ui', 'SIM', 'appearance', 'light'],
    ['ui', 'SIM', 'increase_contrast', 'disabled'],
    ['ui', 'SIM', 'content_size', 'large'],
  ]);
});

test('each setting changes one thing, and puts the others back to their default', () => {
  const changed = (setting) => settingCommands(setting, 'SIM').filter((command, index) => command[3] !== settingCommands(settings[0], 'SIM')[index][3]);
  assert.deepEqual(changed(settings[1]), [['ui', 'SIM', 'content_size', 'accessibility-extra-extra-extra-large']]);
  assert.deepEqual(changed(settings[2]), [['ui', 'SIM', 'appearance', 'dark']]);
  assert.deepEqual(changed(settings[3]), [['ui', 'SIM', 'increase_contrast', 'enabled']]);
});

test('the journeys run twice: once with the settings helper, for the four settings, and once in double length', () => {
  assert.deepEqual(journeyRuns.map((run) => [run.name, run.helper === true, run.doubleLength === true]), [
    ['settings', true, false],
    ['double-length', false, true],
  ]);
});

test('a run has one result bundle for the hosted tests, and one for each run of the journeys', () => {
  const bundles = resultBundles('/run/simulator');
  assert.deepEqual(bundles.hosted, [{ path: '/run/simulator/hosted.xcresult', label: 'the hosted tests' }]);
  assert.deepEqual(bundles.ui, [
    { path: '/run/simulator/journeys-settings.xcresult', label: 'the journeys in the four settings of the audit' },
    { path: '/run/simulator/journeys-double-length.xcresult', label: 'the journeys in the double-length pseudo-language' },
  ]);
});

test("`just build` is the simulator step's build: the same action, destination, folder and architecture", () => {
  const justfile = readFileSync(new URL('../../justfile', import.meta.url), 'utf8');
  const recipe = justfile.slice(justfile.indexOf('\nbuild:\n'), justfile.indexOf('> build/xcodebuild.log'));
  const derivedData = /^derived_data := "(.*)"$/m.exec(justfile)[1];
  // The recipe's `xcodebuild` call as its words, with the justfile's variable filled in.
  const words = recipe
    .slice(recipe.indexOf('xcodebuild '))
    .replaceAll('\\\n', ' ')
    .replaceAll('{{derived_data}}', derivedData)
    .match(/'[^']*'|\S+/g)
    .map((word) => word.replace(/^'(.*)'$/, '$1'));
  assert.deepEqual(words, ['xcodebuild', ...buildArguments]);
  assert.equal(buildArguments[0], 'build-for-testing');
  assert.ok(buildArguments.includes('ARCHS=arm64'));
});

test('the settings helper applies the setting that a journey names, and answers when it is applied', async (t) => {
  const applied = [];
  const helper = await startSettingsHelper(async (setting) => {
    await new Promise((resolve) => setTimeout(resolve, 50));
    applied.push(setting.name);
  });
  t.after(() => helper.close());
  assert.match(helper.address, /^http:\/\/127\.0\.0\.1:\d+$/);
  const post = (name) => fetch(`${helper.address}/settings/${name}`, { method: 'POST' });
  assert.equal((await post('largest-text')).status, 204);
  assert.deepEqual(applied, ['largest-text']);
  assert.equal((await post('dark-mode')).status, 204);
  assert.equal((await post('default')).status, 204);
  assert.deepEqual(applied, ['largest-text', 'dark-mode', 'default']);
  assert.equal((await post('double-length')).status, 404);
  assert.equal((await fetch(`${helper.address}/settings/dark-mode`)).status, 404);
  assert.deepEqual(applied, ['largest-text', 'dark-mode', 'default']);
});

test('the settings helper answers 500, with the reason, when a setting fails to apply', async (t) => {
  const helper = await startSettingsHelper(() => {
    throw new Error('simctl ended with 1');
  });
  t.after(() => helper.close());
  const response = await fetch(`${helper.address}/settings/increase-contrast`, { method: 'POST' });
  assert.equal(response.status, 500);
  assert.equal(await response.text(), 'simctl ended with 1');
});

test("the build's line counts the Swift files that it compiled, and a build with nothing to do compiled none", (t) => {
  const folder = mkdtempSync(path.join(tmpdir(), 'wishbone-gate-test-'));
  t.after(() => rmSync(folder, { recursive: true, force: true }));
  const log = path.join(folder, 'build.log');
  writeFileSync(log, 'SwiftCompile normal arm64 /a.swift\n    cd /\nSwiftCompile normal arm64 /b.swift\nCompileSwift normal arm64 /c.swift\nCodeSign /x.app\n');
  assert.equal(compiledFiles(log), 3);
  writeFileSync(log, 'Copy /a /b\nCodeSign /x.app\nProcessInfoPlistFile /x/Info.plist\n');
  assert.equal(compiledFiles(log), 0);
});

test('the results folder and the flags come in any order, and a flag is never the folder', () => {
  const folder = path.join('build', 'simulator');
  assert.deepEqual(parseArguments([]), { results: folder, build: true });
  assert.deepEqual(parseArguments(['--no-build']), { results: folder, build: false });
  assert.deepEqual(parseArguments(['out', '--no-build']), { results: 'out', build: false });
  assert.deepEqual(parseArguments(['--no-build', 'out']), { results: 'out', build: false });
  assert.throws(() => parseArguments(['--nobuild']), /unknown flag --nobuild/);
  assert.throws(() => parseArguments(['one', 'two']), /one results folder, not 2/);
});

test('the settings applier runs only the simctl calls that change something', async () => {
  const ran = [];
  const applier = settingsApplier('SIM', { run: async (command) => ran.push(command.slice(2).join(' ')) });
  // The first apply sets everything: the simulator can be in any setting from an earlier run.
  await applier.apply(settings[0]);
  assert.deepEqual(ran.splice(0), ['appearance light', 'increase_contrast disabled', 'content_size large']);
  for (const setting of settings.slice(1)) {
    await applier.apply(setting);
    await applier.apply(settings[0]);
  }
  assert.deepEqual(ran.splice(0), [
    'content_size accessibility-extra-extra-extra-large',
    'content_size large',
    'appearance dark',
    'appearance light',
    'increase_contrast enabled',
    'increase_contrast disabled',
  ]);
  await applier.apply(settings[0]);
  assert.deepEqual(ran, []);
  assert.equal(applier.calls(), 9);
  assert.equal(applier.hangs(), 0);
});

test('a simctl call that fails leaves its setting unknown, so the next apply runs it again', async () => {
  const ran = [];
  let failing = true;
  const applier = settingsApplier('SIM', {
    run: async (command) => {
      ran.push(command[2]);
      if (failing && command[2] === 'appearance' && command[3] === 'dark') throw new Error('Invalid device state');
    },
  });
  await applier.apply(settings[0]);
  await assert.rejects(applier.apply(settings[2]), { message: "simctl ui SIM appearance dark Invalid device state, so the simulator isn't in dark mode" });
  failing = false;
  ran.length = 0;
  await applier.apply(settings[0]);
  assert.deepEqual(ran, ['appearance']);
});

/** An error like the one that `simctlWithLimit` gives for a call that passed its limit. */
const hung = () => Object.assign(new Error("didn't return within 30s"), { timedOut: true });

/**
 * A simulator for the applier, on its own clock. It holds each setting's value, answers a read with it, and sets it
 * on a call. `hangs(command)` says whether a call hangs: then it takes its whole limit, and, with `lands`, its
 * setting changes anyway. Returns `{ applier, ran, clock }`: `ran` has each call, with `read` for a read.
 */
function fakeSimulator({ hangs = () => false, lands = false, ...options } = {}) {
  const values = new Map();
  const ran = [];
  const clock = { ms: 0, longest: 0 };
  let applyStarted = 0;
  const applier = settingsApplier('SIM', {
    run: async (command, limitMs) => {
      const [, , name, value] = command;
      ran.push(value === undefined ? `read ${name}` : `${name} ${value}`);
      if (value === undefined) {
        clock.ms += 1;
        return `${values.get(name) ?? 'unknown'}\n`;
      }
      if (hangs(command, ran)) {
        clock.ms += limitMs;
        if (lands) values.set(name, value);
        throw hung();
      }
      clock.ms += 1_000;
      values.set(name, value);
      return '';
    },
    now: () => clock.ms,
    sleep: async (ms) => {
      clock.ms += ms;
    },
    ...options,
  });
  const apply = async (setting, more) => {
    applyStarted = clock.ms;
    try {
      return await applier.apply(setting, more);
    } finally {
      clock.longest = Math.max(clock.longest, clock.ms - applyStarted);
    }
  };
  return { applier: { ...applier, apply }, ran, clock };
}

test('a simctl call that hangs, and whose setting reads back unchanged, is run again, and the applier counts the hang', async () => {
  const { applier, ran } = fakeSimulator({ hangs: (command, calls) => command[3] === 'dark' && calls.filter((one) => one === 'appearance dark').length === 1 });
  await applier.apply(settings[0]);
  await applier.apply(settings[2]);
  assert.deepEqual(ran.slice(3), ['appearance dark', 'read appearance', 'appearance dark']);
  assert.equal(applier.calls(), 5);
  assert.equal(applier.hangs(), 1);
});

test('a simctl call that hangs, but whose setting reads back as set, did its work and is not run again', async () => {
  const { applier, ran } = fakeSimulator({ hangs: (command) => command[3] === 'dark', lands: true });
  await applier.apply(settings[0]);
  await applier.apply(settings[2]);
  assert.deepEqual(ran.slice(3), ['appearance dark', 'read appearance']);
  assert.equal(applier.hangs(), 1);
  // The applier knows the simulator is in dark mode, so the way back is one call.
  await applier.apply(settings[0]);
  assert.deepEqual(ran.slice(5), ['appearance light']);
});

test('the applier waits after a hang, before it reads the setting back', async () => {
  const waits = [];
  const { applier } = fakeSimulator({
    hangs: (command, calls) => command[3] === 'dark' && calls.filter((one) => one === 'appearance dark').length === 1,
    sleep: async (ms) => waits.push(ms),
  });
  await applier.apply(settings[0]);
  await applier.apply(settings[2]);
  assert.deepEqual(waits, [5_000]);
});

test('a simctl call that hangs for a minute, as on a CI runner, is run until the simulator answers again', async () => {
  // Seen on CI: two calls in a row hung, and the simulator answered a minute or two later.
  let hangsLeft = 0;
  const { applier, ran } = fakeSimulator({ hangs: (command) => command[3] === 'disabled' && hangsLeft-- > 0 });
  await applier.apply(settings[0]);
  hangsLeft = 3;
  await applier.apply(settings[3]);
  await applier.apply(settings[0]);
  assert.deepEqual(ran.slice(4), [
    'increase_contrast disabled',
    'read increase_contrast',
    'increase_contrast disabled',
    'read increase_contrast',
    'increase_contrast disabled',
    'read increase_contrast',
    'increase_contrast disabled',
  ]);
  assert.equal(applier.hangs(), 3);
});

test('a simctl call that keeps hanging fails the setting within the answer limit, with the setting, the call and its hangs in the error', async () => {
  const { applier, clock } = fakeSimulator({ hangs: (command) => command[2] === 'content_size' && command[3] !== 'large' });
  await applier.apply(settings[0]);
  await assert.rejects(applier.apply(settings[1]), {
    message: "simctl ui SIM content_size accessibility-extra-extra-extra-large didn't return within 30s, 5 times in 2m55s, so the simulator isn't in the largest text size",
  });
  assert.equal(applier.hangs(), 5);
  assert.ok(clock.longest <= helperAnswerLimitMs, `the apply took ${clock.longest}ms`);
});

test("no call starts that could end after the helper's answer limit, also when an earlier call of the change used the time", async () => {
  // The appearance hangs until the change has no time left for another try, so the content size isn't run.
  const { applier, ran, clock } = fakeSimulator({ hangs: (command) => command[3] === 'light' });
  await assert.rejects(applier.apply(settings[0]), /^Error: simctl ui SIM appearance light didn't return within 30s, 5 times/);
  assert.ok(clock.longest <= helperAnswerLimitMs, `the apply took ${clock.longest}ms`);
  assert.ok(!ran.includes('content_size large'));
  // A change whose earlier call hung three times, and then answered, leaves the next call no time, and says so.
  const slow = fakeSimulator({ hangs: (command, calls) => command[3] === 'light' && calls.length < 7, answerLimitMs: 135_500 });
  await assert.rejects(slow.applier.apply(settings[0]), {
    message: /^simctl ui SIM increase_contrast disabled wasn't run: the change's earlier calls took its 2m1\ds, so the simulator isn't in the default settings$/,
  });
  assert.deepEqual(slow.ran.at(-1), 'appearance light');
  assert.ok(slow.clock.longest <= 135_500);
});

test('a read that fails or hangs after a hang counts as a setting that is not set, so the call runs again', async () => {
  let first = true;
  const applier = settingsApplier('SIM', {
    run: async (command) => {
      if (command.length === 3) throw hung();
      if (command[3] === 'dark' && first) {
        first = false;
        throw hung();
      }
      return '';
    },
    sleep: async () => {},
  });
  await applier.apply(settings[0]);
  await applier.apply(settings[2]);
  assert.equal(applier.calls(), 5);
});

test("after a hang, the applier records the Mac's state before it reads the setting back, and keeps the record's line", async () => {
  const order = [];
  const { applier, ran } = fakeSimulator({
    hangs: (command, calls) => command[3] === 'dark' && calls.filter((one) => one === 'appearance dark').length === 1,
    record: async () => {
      order.push(`record after ${ran.at(-1)}`);
      return 'CPU 0% idle';
    },
  });
  await applier.apply(settings[0]);
  await applier.apply(settings[2]);
  assert.deepEqual(order, ['record after appearance dark']);
  assert.deepEqual(ran.slice(3), ['appearance dark', 'read appearance', 'appearance dark']);
  assert.deepEqual(applier.records(), ['simctl ui SIM appearance dark: CPU 0% idle']);
});

test("a record that fails doesn't fail the change, and none runs that could end after the change's time", async () => {
  const failing = fakeSimulator({
    hangs: (command, calls) => command[3] === 'dark' && calls.filter((one) => one === 'appearance dark').length === 1,
    record: async () => {
      throw new Error('ps is gone');
    },
  });
  await failing.applier.apply(settings[0]);
  await failing.applier.apply(settings[2]);
  assert.deepEqual(failing.applier.records(), ['simctl ui SIM appearance dark: the record failed: ps is gone']);
  let recorded = 0;
  const tight = fakeSimulator({
    hangs: (command) => command[3] === 'dark',
    answerLimitMs: settingCallLimitMs + recordLimitMs - 1,
    record: async () => {
      recorded += 1;
      return 'CPU 0% idle';
    },
  });
  await tight.applier.apply(settings[0]);
  await assert.rejects(tight.applier.apply(settings[2]), /appearance dark didn't return within 30s/);
  assert.equal(recorded, 0);
});

test("an apply can give its calls a longer limit, as the step's start does while the simulator gets ready", async () => {
  const limits = [];
  const applier = settingsApplier('SIM', { run: async (command, limitMs) => limits.push(limitMs) });
  await applier.apply(settings[0], { limitMs: 300_000, answerLimitMs: readinessAnswerLimitMs });
  await applier.apply(settings[1]);
  assert.deepEqual(limits, [300_000, 300_000, 300_000, 30_000]);
});

test("at the step's start, a call that hangs once is read back and run again", async () => {
  const { applier, ran } = fakeSimulator({ hangs: (command, calls) => calls.length === 1 });
  await applier.apply(settings[0], { limitMs: readinessCallLimitMs, answerLimitMs: readinessAnswerLimitMs });
  assert.deepEqual(ran, ['appearance light', 'read appearance', 'appearance light', 'increase_contrast disabled', 'content_size large']);
});

test('a call that passes its limit is stopped, and its error says it timed out', async () => {
  const started = Date.now();
  await assert.rejects(simctlWithLimit(['60'], 200, { file: 'sleep', prefix: [] }), (error) => error.timedOut === true && /didn't return within 0s/.test(error.message));
  // The call sleeps for 60 s, so one that ran to its end took longer than that.
  assert.ok(Date.now() - started < 60_000, 'the call was stopped at its limit');
  // These calls are not about the limit, so it is far past their work: a busy machine can take seconds to start one.
  const noLimitMs = 60 * 60_000;
  await assert.rejects(simctlWithLimit(['-c', 'echo "No devices are booted." >&2; exit 1'], noLimitMs, { file: 'sh', prefix: [] }), (error) => error.timedOut === false && error.message === 'No devices are booted.');
  assert.equal(await simctlWithLimit(['-c', 'echo ok'], noLimitMs, { file: 'sh', prefix: [] }), 'ok\n');
});

test('the settings helper answers 500, with the reason, when a hung call fails a setting', async (t) => {
  // A hang on the applier's own clock: there is no time left for another try.
  const { applier } = fakeSimulator({ hangs: () => true, answerLimitMs: 30_000 });
  const helper = await startSettingsHelper((setting) => applier.apply(setting));
  t.after(() => helper.close());
  const response = await fetch(`${helper.address}/settings/default`, { method: 'POST' });
  assert.equal(response.status, 500);
  assert.equal(await response.text(), "simctl ui SIM appearance light didn't return within 30s, once in 30s, so the simulator isn't in the default settings");
});

test('the settings helper says to audit a screen the first time a journey names it, and not again in that run', async (t) => {
  const helper = await startSettingsHelper(async () => {});
  t.after(() => helper.close());
  const claim = (screen) => fetch(`${helper.address}/screens`, { method: 'POST', body: screen });
  // The first journey reaches the signed-out screen and Home. A later journey reaches Home again, and Lists.
  assert.equal((await claim('the signed-out screen')).status, 201);
  assert.equal((await claim('Home')).status, 201);
  assert.equal((await claim('Home')).status, 200);
  assert.equal((await claim('Lists')).status, 201);
  assert.equal((await claim('the signed-out screen')).status, 200);
  // A name is the whole name, with its spaces, commas and slashes.
  assert.equal((await claim('Home, in a sheet / again')).status, 201);
  assert.equal((await claim('')).status, 400);
  assert.equal((await fetch(`${helper.address}/screens`)).status, 404);
  assert.deepEqual(helper.screens(), ['the signed-out screen', 'Home', 'Lists', 'Home, in a sheet / again']);
});

test('a new settings helper, for a new run, audits every screen again', async (t) => {
  const first = await startSettingsHelper(async () => {});
  t.after(() => first.close());
  assert.equal((await fetch(`${first.address}/screens`, { method: 'POST', body: 'Home' })).status, 201);
  const second = await startSettingsHelper(async () => {});
  t.after(() => second.close());
  assert.equal((await fetch(`${second.address}/screens`, { method: 'POST', body: 'Home' })).status, 201);
});

test('the settings applier applies one setting at a time, so a journey never overlaps a call that is still running', async () => {
  const ran = [];
  let running = 0;
  const applier = settingsApplier('SIM', {
    run: async (command) => {
      running += 1;
      assert.equal(running, 1, 'two simctl calls ran at once');
      await new Promise((resolve) => setTimeout(resolve, 10));
      ran.push(command[3]);
      running -= 1;
    },
  });
  // The first apply is still running when the next two come, as when a journey's request timed out and the next
  // journey asks for its setting.
  await Promise.all([applier.apply(settings[0]), applier.apply(settings[2]), applier.apply(settings[0])]);
  assert.deepEqual(ran, ['light', 'disabled', 'large', 'dark', 'light']);
});

test('a failed apply does not stop the next one', async () => {
  const ran = [];
  const applier = settingsApplier('SIM', {
    run: async (command) => {
      ran.push(command[3]);
      if (command[3] === 'dark') throw new Error('Invalid device state');
    },
  });
  await applier.apply(settings[0]);
  const failed = applier.apply(settings[2]);
  const next = applier.apply(settings[0]);
  await assert.rejects(failed, /Invalid device state/);
  await next;
  // The failed call left the appearance unknown, so the next apply set it again.
  assert.deepEqual(ran.slice(3), ['dark', 'light']);
});

test("a journey waits for the helper longer than the helper's longest answer", () => {
  const audit = readFileSync(new URL('../../JourneyTests/Audit.swift', import.meta.url), 'utf8');
  const seconds = Number(/static let helperTimeout: TimeInterval = (\d+)/.exec(audit)[1]);
  assert.ok(seconds * 1000 > helperAnswerLimitMs, `Audit.swift waits ${seconds}s, and the helper can take ${helperAnswerLimitMs / 1000}s`);
  // A call that hangs gets at least two tries more in a change.
  assert.ok(helperAnswerLimitMs >= 3 * settingCallLimitMs + 2 * (settingPauseMs + settingReadLimitMs));
});

const signIn = 'JourneyTests.SignInJourney/testSignIn()';
const signOut = 'JourneyTests.SignOutJourney/testSignOut()';
const runnerError = 'JourneyTests.JourneyTests-Runner (27397) encountered an error';
const noProcessID = "SignInJourney.swift:37: Application 'com.codemonkeylabs.wishbone' does not have a process ID";
/** A reading of a run of the journeys, with `tests` mapping a name to its outcome, and `messages` as the fixture's. */
const journeysReading = (tests, messages = {}) => readTestResults(testResults(tests, { messages }));

test("a launch that got no process ID is the launch flake, as it shows on a busy Mac", () => {
  const reading = journeysReading({ [signIn]: 'fail', [signOut]: 'pass' }, { [signIn]: [noProcessID] });
  assert.deepEqual(launchFlakeIn(reading), [signIn]);
});

test("a launch that got no process ID is the launch flake also when the test runner's error follows, as on CI", () => {
  const reading = journeysReading({ [signIn]: 'fail', [runnerError]: 'fail', [signOut]: 'pass' }, { [signIn]: [noProcessID], [runnerError]: ['The test runner encountered an error'] });
  assert.deepEqual(launchFlakeIn(reading), [signIn]);
});

test('each journey whose launch got no process ID is named', () => {
  const signOutMessage = "SignOutJourney.swift:36: Application 'com.codemonkeylabs.wishbone' does not have a process ID";
  const reading = journeysReading({ [signIn]: 'fail', [signOut]: 'fail' }, { [signIn]: [noProcessID], [signOut]: [signOutMessage] });
  assert.deepEqual(launchFlakeIn(reading), [signIn, signOut]);
});

test('a launch that got its process ID and then crashed is not the launch flake', () => {
  const crashed = "SignInJourney.swift:48: com.codemonkeylabs.wishbone (4242) crashed in Session.restore() (EXC_BAD_ACCESS)";
  assert.equal(launchFlakeIn(journeysReading({ [signIn]: 'fail' }, { [signIn]: [crashed] })), null);
});

test("the test runner's error with no launch that failed is not the launch flake", () => {
  assert.equal(launchFlakeIn(journeysReading({ [signIn]: 'pass', [runnerError]: 'fail' }, { [runnerError]: ['The test runner encountered an error'] })), null);
});

test('a failure of any other kind beside the launch flake is not the launch flake', () => {
  const tests = { [signIn]: 'fail', [signOut]: 'fail' };
  assert.equal(launchFlakeIn(journeysReading(tests, { [signIn]: [noProcessID], [signOut]: ['SignOutJourney.swift:60: Sign out did not show'] })), null);
  // A journey whose launch got no process ID in one place, and that failed in another, failed in the other too.
  assert.equal(launchFlakeIn(journeysReading({ [signIn]: 'fail' }, { [signIn]: [noProcessID, 'SignInJourney.swift:80: Home did not show'] })), null);
  // A failed test with no message says nothing about why.
  assert.equal(launchFlakeIn(journeysReading({ [signIn]: 'fail' }, { [signIn]: [] })), null);
});

test('a run that passed, or that has no summary, is not the launch flake', () => {
  assert.equal(launchFlakeIn(journeysReading({ [signIn]: 'pass' })), null);
  assert.equal(launchFlakeIn(readTestResults(undefined)), null);
});

const claim = 'JourneyTests.ClaimJourney/testClaim()';
const noAssertion = 'ClaimJourney.swift:49: Failed to get background assertion for target app with pid 32833: No failure details provided';

test('a launch that got no background assertion is the launch flake, as it showed on a busy Mac', () => {
  assert.deepEqual(launchFlakeIn(journeysReading({ [claim]: 'fail', [signIn]: 'pass' }, { [claim]: [noAssertion] })), [claim]);
});

test('launches that got no process ID and a launch that got no background assertion, in one run, are the launch flake', () => {
  // The sighting of 2026-11-23: two journeys' launches got no process ID, and the claim journey's got no assertion.
  const tests = { [signIn]: 'fail', [signOut]: 'fail', [claim]: 'fail' };
  const signOutMessage = "SignOutJourney.swift:36: Application 'com.codemonkeylabs.wishbone' does not have a process ID";
  const reading = journeysReading(tests, { [signIn]: [noProcessID], [signOut]: [signOutMessage], [claim]: [noAssertion] });
  assert.deepEqual(launchFlakeIn(reading), [claim, signIn, signOut]);
});

test('a launch that got no background assertion, in a journey that failed somewhere else too, is not the launch flake', () => {
  assert.equal(launchFlakeIn(journeysReading({ [claim]: 'fail' }, { [claim]: [noAssertion, 'ClaimJourney.swift:80: Claimed did not show'] })), null);
});

test("the launch flake's message is XCTest's, for any app", () => {
  assert.match("Application 'com.example.other' does not have a process ID", launchFlake.message);
  assert.doesNotMatch("Application 'com.codemonkeylabs.wishbone' has a process ID", launchFlake.message);
  assert.match('Failed to get background assertion for target app with pid 1: No failure details provided', launchFlake.message);
  // The test runner's own assertion, which XCTest asks for when it sends the runner to the background, is another failure.
  assert.doesNotMatch('Failed to get reply to request for background assertion within 30.0s', launchFlake.message);
});

/** A run of the journeys that ends as each of `outcomes` says in turn: `flake`, `fail`, or `pass`. */
function journeysRuns(...outcomes) {
  const runs = [];
  const readings = {
    flake: { passed: false, reading: journeysReading({ [signIn]: 'fail' }, { [signIn]: [noProcessID] }) },
    hang: { passed: false, reading: journeysReading({ [claim]: 'fail', [signIn]: 'pass' }, { [claim]: [hungChange] }) },
    fail: { passed: false, reading: journeysReading({ [signIn]: 'fail' }, { [signIn]: ['SignInJourney.swift:80: Home did not show'] }) },
    pass: { passed: true, reading: journeysReading({ [signIn]: 'pass' }) },
  };
  return {
    runOnce: async () => {
      runs.push(outcomes[runs.length]);
      return readings[outcomes[runs.length - 1]];
    },
    runs,
  };
}

test('journeys that fail with the launch flake run again once, keep the first run, and pass when the second run passes', async () => {
  const { runOnce, runs } = journeysRuns('flake', 'pass');
  const lines = [];
  let kept = 0;
  const passed = await runAgainOnFlake(runOnce, { keep: () => (kept += 1, ['first.xcresult', 'first.log']), say: (line) => lines.push(line) });
  assert.equal(passed, true);
  assert.deepEqual(runs, ['flake', 'pass']);
  assert.equal(kept, 1);
  assert.deepEqual(lines, [
    `  ${signIn}: XCTest gave up on the launch (the named flake "${launchFlake.name}"), so this run of the journeys runs again, once. The first run is in first.xcresult and first.log.`,
  ]);
});

test('journeys that fail with the launch flake twice are red: they run again only once', async () => {
  const { runOnce, runs } = journeysRuns('flake', 'flake', 'pass');
  assert.equal(await runAgainOnFlake(runOnce, { keep: () => [], say: () => {} }), false);
  assert.deepEqual(runs, ['flake', 'flake']);
});

test('journeys that fail in another way, after the launch flake, are red', async () => {
  const { runOnce, runs } = journeysRuns('flake', 'fail');
  assert.equal(await runAgainOnFlake(runOnce, { keep: () => [], say: () => {} }), false);
  assert.deepEqual(runs, ['flake', 'fail']);
});

test('journeys that pass, or that fail in another way, run once', async () => {
  for (const outcome of ['pass', 'fail']) {
    const { runOnce, runs } = journeysRuns(outcome, 'pass');
    const lines = [];
    let kept = 0;
    assert.equal(await runAgainOnFlake(runOnce, { keep: () => (kept += 1, []), say: (line) => lines.push(line) }), outcome === 'pass');
    assert.deepEqual(runs, [outcome]);
    assert.equal(kept, 0);
    assert.deepEqual(lines, []);
  }
});

/** The failure of run 45956119178's journeys-1 on CI, as the gate reads it. */
const hungChange =
  "failed - The settings helper didn't apply the largest text size: simctl ui 5E435B5F-954B-439A-9020-B93EF4C3D276 content_size accessibility-extra-extra-extra-large didn't return within 30s, once in 2m53s, so the simulator isn't in the largest text size";

test("a journey that failed only because a simctl ui call hung is the hang flake, as on CI", () => {
  assert.deepEqual(hangFlakeIn(journeysReading({ [claim]: 'fail', [signIn]: 'pass' }, { [claim]: [hungChange] })), [claim]);
  // Run 45898045293: the change back to the default.
  const people = 'JourneyTests.PeopleJourney/testPeople()';
  const toDefault =
    "failed - The settings helper didn't apply the default settings: simctl ui CDD71CA6-C0F5-43ED-98B1-D883F0C77575 increase_contrast disabled didn't return within 30s, 3 times in 2m55s, so the simulator isn't in the default settings";
  assert.deepEqual(hangFlakeIn(journeysReading({ [people]: 'fail' }, { [people]: [toDefault] })), [people]);
  // A call that a hang before it left no time for.
  const notRun =
    "failed - The settings helper didn't apply the default settings: simctl ui SIM increase_contrast disabled wasn't run: the change's earlier calls took its 3m00s, so the simulator isn't in the default settings";
  assert.deepEqual(hangFlakeIn(journeysReading({ [people]: 'fail' }, { [people]: [notRun] })), [people]);
});

test('a call that failed in another way, or a failure of any other kind beside the hang, is not the hang flake', () => {
  const invalid = "failed - The settings helper didn't apply dark mode: simctl ui SIM appearance dark Invalid device state, so the simulator isn't in dark mode";
  assert.equal(hangFlakeIn(journeysReading({ [claim]: 'fail' }, { [claim]: [invalid] })), null);
  assert.equal(hangFlakeIn(journeysReading({ [claim]: 'fail', [signIn]: 'fail' }, { [claim]: [hungChange], [signIn]: ['SignInJourney.swift:80: Home did not show'] })), null);
  assert.equal(hangFlakeIn(journeysReading({ [claim]: 'fail' }, { [claim]: [hungChange, 'ClaimJourney.swift:80: Claimed did not show'] })), null);
  assert.equal(hangFlakeIn(journeysReading({ [claim]: 'fail' }, { [claim]: [] })), null);
  assert.equal(hangFlakeIn(journeysReading({ [claim]: 'pass' })), null);
  assert.equal(hangFlakeIn(readTestResults(undefined)), null);
});

test('journeys that fail with the hang flake run again once, keep the first run, and say so', async () => {
  const { runOnce, runs } = journeysRuns('hang', 'pass');
  const lines = [];
  assert.equal(await runAgainOnFlake(runOnce, { keep: () => ['first.xcresult', 'first.log'], say: (line) => lines.push(line) }), true);
  assert.deepEqual(runs, ['hang', 'pass']);
  assert.deepEqual(lines, [
    `  ${claim}: a simctl ui call hung until the change had no time left (the named flake "${hangFlake.name}"), so this run of the journeys runs again, once. The first run is in first.xcresult and first.log.`,
  ]);
});

test('journeys run again only once, whichever flake failed them', async () => {
  for (const outcomes of [['hang', 'hang'], ['hang', 'flake'], ['flake', 'hang'], ['hang', 'fail']]) {
    const { runOnce, runs } = journeysRuns(...outcomes, 'pass');
    assert.equal(await runAgainOnFlake(runOnce, { keep: () => [], say: () => {} }), false);
    assert.deepEqual(runs, outcomes);
  }
});

test('a call that passes its limit returns at its limit, also when a process that it started keeps its output open', async () => {
  // The shell's child sleeps on with the shell's output, as a process that `simctl spawn` starts in the simulator does.
  const marker = `${30 + Math.floor(Math.random() * 1000) / 1000}`;
  const started = Date.now();
  await assert.rejects(runWithLimit('sh', ['-c', `sleep ${marker} & sleep ${marker}`], 500), (error) => error.timedOut === true);
  assert.ok(Date.now() - started < 20_000, `the call returned after ${Date.now() - started}ms`);
  // The whole process group was stopped: no sleep is left behind. A busy machine can take a moment to end it.
  const { execFileSync } = await import('node:child_process');
  const left = () => {
    try {
      return execFileSync('pgrep', ['-f', `sleep ${marker}`], { encoding: 'utf8' }).trim();
    } catch {
      return '';
    }
  };
  for (let tries = 0; tries < 100 && left() !== ''; tries += 1) await new Promise((resolve) => setTimeout(resolve, 100));
  assert.equal(left(), '');
});

test("a call that ends gives its output, and one that fails gives its error's words", async () => {
  const noLimitMs = 60 * 60_000;
  assert.equal(await runWithLimit('sh', ['-c', 'echo ok'], noLimitMs), 'ok\n');
  await assert.rejects(runWithLimit('sh', ['-c', 'echo "No devices are booted." >&2; exit 1'], noLimitMs), (error) => error.timedOut === false && error.message === 'No devices are booted.');
  await assert.rejects(runWithLimit('no-such-program-wt304', [], noLimitMs), (error) => error.timedOut === false && /ENOENT/.test(error.message));
});

/** `ps -axo pid=,stat=,%cpu=,etime=,comm=` on a Mac with the gate's simulator, cut short. */
const hostPs = [
  '  101 Ss     0.0 02:10:00 /sbin/launchd',
  '  812 S      4.1    12:34 /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/XPCServices/com.apple.CoreSimulator.CoreSimulatorService.xpc/Contents/MacOS/com.apple.CoreSimulator.CoreSimulatorService',
  ' 4100 Ss     0.0    10:02 launchd_sim',
  ' 4242 Ss    97.5    09:58 /usr/libexec/CoreSimulatorBridge',
  ' 5000 R     50.0    00:30 /usr/bin/xcodebuild',
].join('\n');

const serviceSample = [
  'Sort by top of stack, same collapsed (when >= 5):',
  '        mach_msg2_trap  (in libsystem_kernel.dylib)        1800',
  '        __psynch_cvwait  (in libsystem_kernel.dylib)        900',
  '        kevent_id  (in libsystem_kernel.dylib)        12',
  '        __ulock_wait2  (in libsystem_kernel.dylib)        6',
  '',
].join('\n');

const topOutput = ['Processes: 500 total', 'CPU usage: 50.0% user, 30.0% sys, 20.0% idle', 'Processes: 500 total', 'CPU usage: 70.12% user, 29.0% sys, 0.88% idle', ''].join('\n');

/** The calls of a `hangRecord` on a fake host. `fails(file)` gives an error for a call that fails. */
function fakeHost(t, { fails = () => null } = {}) {
  const directory = mkdtempSync(path.join(tmpdir(), 'hang-record-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const ran = [];
  const host = async (file, args, limitMs) => {
    ran.push(`${file} ${args.join(' ')} (${limitMs}ms)`);
    const error = fails(file);
    if (error !== null) throw error;
    if (file === 'ps') return `${hostPs}\n`;
    if (file === 'top') return topOutput;
    if (file === 'sample') writeFileSync(args[3], serviceSample);
    return '';
  };
  return { record: hangRecord({ directory, host, relative: (file) => path.basename(file) }), ran, directory };
}

test("a hang's record says what the Mac was doing, from the Mac alone, with no simctl call", async (t) => {
  const { record, ran, directory } = fakeHost(t);
  assert.equal(
    await record(),
    'CPU 0.88% idle; launchd_sim 4100 Ss 0.0%; CoreSimulatorBridge 4242 Ss 97.5%; CoreSimulatorService 812 S 4.1%, ' +
      'top of its stack: mach_msg2_trap 1800, __psynch_cvwait 900, kevent_id 12 (record: hang-1.txt)',
  );
  assert.deepEqual(
    ran.map((one) => one.replace(directory, 'DIR')),
    ['top -l 2 -n 0 (10000ms)', 'ps -axo pid=,stat=,%cpu=,etime=,comm= (5000ms)', 'sample 812 1 -file DIR/hang-1-service-sample.txt (10000ms)'],
  );
  assert.ok(!ran.some((one) => one.includes('simctl')));
  // The record's file has the processes and the sample, for a person to read.
  const kept = readFileSync(path.join(directory, 'hang-1.txt'), 'utf8');
  assert.match(kept, /CoreSimulatorBridge/);
  assert.match(kept, /mach_msg2_trap/);
  await record();
  assert.ok(existsSync(path.join(directory, 'hang-2.txt')));
});

test('the limits of a record add up to its limit', () => {
  assert.equal(recordLimitMs, 10_000 + 5_000 + 10_000);
});

test("a record goes on when one of its calls fails, and says which", async (t) => {
  const noTop = fakeHost(t, { fails: (file) => (file === 'top' ? Object.assign(new Error("didn't return within 10s"), { timedOut: true }) : null) });
  assert.match(await noTop.record(), /^CPU unread \(didn't return within 10s\); launchd_sim 4100/);
  const noPs = fakeHost(t, { fails: (file) => (file === 'ps' ? new Error('ps: Operation not permitted') : null) });
  assert.match(await noPs.record(), /^CPU 0\.88% idle; processes unread \(ps: Operation not permitted\) \(record: hang-1\.txt\)$/);
  assert.ok(!noPs.ran.some((one) => one.startsWith('sample')));
  const noSample = fakeHost(t, { fails: (file) => (file === 'sample' ? new Error('sample: no such process') : null) });
  assert.match(await noSample.record(), /CoreSimulatorService 812 S 4\.1%, not sampled \(sample: no such process\) \(record: hang-1\.txt\)$/);
});

test("the lines after the journeys give each hang's record, under the flake's name", () => {
  assert.deepEqual(hangRecordLines([]), []);
  assert.deepEqual(hangRecordLines(['simctl ui SIM appearance dark: CPU 0% idle']), [
    `  At each hang, the Mac had (the named flake "${hangFlake.name}"):`,
    '    simctl ui SIM appearance dark: CPU 0% idle',
  ]);
});

test("the first run's bundle and log move aside, so the second run writes its own at the run's paths", (t) => {
  const directory = mkdtempSync(path.join(tmpdir(), 'wishbone-gate-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const bundle = path.join(directory, 'journeys-settings.xcresult');
  mkdirSync(bundle);
  writeFileSync(path.join(bundle, 'Info.plist'), 'first');
  writeFileSync(path.join(directory, 'journeys-settings.log'), 'first log');
  // A first try from an earlier gate's run is replaced.
  mkdirSync(path.join(directory, 'journeys-settings-first.xcresult'));
  writeFileSync(path.join(directory, 'journeys-settings-first.log'), 'older');

  const kept = keepFirstTry(directory, bundle, 'journeys-settings.log');
  assert.deepEqual(kept, [path.join(directory, 'journeys-settings-first.xcresult'), path.join(directory, 'journeys-settings-first.log')]);
  assert.equal(existsSync(bundle), false);
  assert.equal(existsSync(path.join(directory, 'journeys-settings.log')), false);
  assert.equal(readFileSync(path.join(kept[0], 'Info.plist'), 'utf8'), 'first');
  assert.equal(readFileSync(kept[1], 'utf8'), 'first log');
});

test('a run that died before it wrote its bundle or its log has nothing to move aside', (t) => {
  const directory = mkdtempSync(path.join(tmpdir(), 'wishbone-gate-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const kept = keepFirstTry(directory, path.join(directory, 'journeys-settings.xcresult'), 'journeys-settings.log');
  assert.equal(existsSync(kept[0]), false);
  assert.equal(existsSync(kept[1]), false);
});

test("the settings helper sends a change again from the setting before it, and remembers it with what the simulator read", async (t) => {
  const { applier, ran } = fakeSimulator();
  await applier.apply(settings[0]);
  const limits = [];
  const helper = await startSettingsHelper(
    (setting, options) => {
      limits.push(options?.answerLimitMs);
      return applier.apply(setting, options);
    },
    { readSettings: () => applier.read() },
  );
  t.after(() => helper.close());
  const post = (path) => fetch(`${helper.address}/settings/${path}`, { method: 'POST' });
  assert.equal((await post('dark-mode')).status, 204);
  ran.splice(0);
  // The app went on showing the light screen, so the journey sends the change to dark mode again.
  assert.equal((await post('dark-mode?after=default')).status, 204);
  assert.deepEqual(ran.splice(0), ['read appearance', 'read increase_contrast', 'read content_size', 'appearance light', 'appearance dark']);
  // And back to the default, from dark mode.
  assert.equal((await post('default')).status, 204);
  assert.equal((await post('default?after=dark-mode')).status, 204);
  assert.deepEqual(ran.splice(-3), ['read content_size', 'appearance dark', 'appearance light']);
  // A change sent again is a read and two changes, which share the helper's answer limit, so the journey's wait
  // still holds. Each change has time for a call that hangs once, a read, and the call again.
  const share = resendAnswerLimitMs;
  assert.deepEqual(limits, [undefined, share, share, undefined, share, share]);
  assert.ok(3 * settingReadLimitMs + 2 * share <= helperAnswerLimitMs);
  assert.ok(2 * settingCallLimitMs + settingPauseMs + settingReadLimitMs <= share);
  assert.deepEqual(helper.resends(), [
    { setting: 'dark mode', after: 'the default settings', read: 'appearance dark, increase_contrast disabled, content_size large' },
    { setting: 'the default settings', after: 'dark mode', read: 'appearance light, increase_contrast disabled, content_size large' },
  ]);
  // A change from a setting that doesn't exist, or from the setting itself, is no change.
  assert.equal((await post('dark-mode?after=double-length')).status, 404);
  assert.equal((await post('dark-mode?after=dark-mode')).status, 404);
  assert.equal(helper.resends().length, 2);
});

test('the settings helper remembers each audit that ran again after it ran out of time, in order', async (t) => {
  const { applier, ran } = fakeSimulator();
  const helper = await startSettingsHelper((setting, options) => applier.apply(setting, options));
  t.after(() => helper.close());
  const post = (body, method = 'POST') => fetch(`${helper.address}/audit-retries`, { method, body });
  assert.deepEqual(helper.auditRetries(), []);
  assert.equal((await post('Home, in the default settings')).status, 204);
  assert.equal((await post('Home, in the default settings')).status, 204);
  assert.equal((await post('the Add screen, in dark mode')).status, 204);
  assert.deepEqual(helper.auditRetries(), ['Home, in the default settings', 'Home, in the default settings', 'the Add screen, in dark mode']);
  // An audit with no name, or a request that isn't a POST, is not a retry.
  assert.equal((await post('')).status, 400);
  assert.equal((await post(undefined, 'GET')).status, 404);
  assert.equal(helper.auditRetries().length, 3);
  // A retry changes no setting, and is not a screen that the run audited.
  assert.deepEqual(ran, []);
  assert.deepEqual(helper.screens(), []);
});

test('the line after the journeys names each audit that ran again, and the flake, and there is none when none did', () => {
  assert.deepEqual(auditRetryLines([]), []);
  assert.deepEqual(auditRetryLines(['Home, in the default settings']), [
    `  The journeys ran 1 audit again, because XCTest said that it didn't complete in time (the named flake "${auditTimeOutFlake}"):`,
    '    Home, in the default settings.',
  ]);
  assert.match(auditRetryLines(['a', 'b'])[0], /ran 2 audits again/);
});

test("a journey runs a timed-out audit again a bounded number of times, and only on XCTest's time-out", () => {
  const audit = readFileSync(new URL('../../JourneyTests/Audit.swift', import.meta.url), 'utf8');
  const limit = Number(/static let auditRetryLimit = (\d+)/.exec(audit)[1]);
  assert.ok(limit >= 1 && limit <= 2, `Audit.swift runs a timed-out audit again ${limit} times`);
  assert.match(audit, /error\.domain == "com\.apple\.xcode\.xctest\.accessibilityAudit" && error\.code == -56/);
  // The journey reports each retry at the path that the helper reads.
  assert.match(audit, /helper\.appending\(path: path\)/);
  assert.match(audit, /reportRetry\(audited, at: "audit-retries"\)/);
});

test('the settings helper remembers each audit that ran again for an issue with no element, apart from the time-outs', async (t) => {
  const { applier, ran } = fakeSimulator();
  const helper = await startSettingsHelper((setting, options) => applier.apply(setting, options));
  t.after(() => helper.close());
  const post = (body, method = 'POST') => fetch(`${helper.address}/lost-element-retries`, { method, body });
  assert.deepEqual(helper.lostElementRetries(), []);
  assert.equal((await post('Home, in the largest text size')).status, 204);
  assert.deepEqual(helper.lostElementRetries(), ['Home, in the largest text size']);
  // An audit with no name, or a request that isn't a POST, is not a retry.
  assert.equal((await post('')).status, 400);
  assert.equal((await post(undefined, 'GET')).status, 404);
  assert.equal(helper.lostElementRetries().length, 1);
  // It is not an audit that timed out, changes no setting, and is not a screen.
  assert.deepEqual(helper.auditRetries(), []);
  assert.deepEqual(ran, []);
  assert.deepEqual(helper.screens(), []);
});

test('the line after the journeys names each audit run again for an issue with no element, and the flake', () => {
  assert.deepEqual(lostElementRetryLines([]), []);
  assert.deepEqual(lostElementRetryLines(['Home, in the largest text size']), [
    `  The journeys ran 1 audit again, because an issue had no element (the named flake "${lostElementFlake}"):`,
    '    Home, in the largest text size.',
  ]);
  assert.match(lostElementRetryLines(['a', 'b'])[0], /ran 2 audits again/);
});

test('a journey runs an audit again for an issue with no element a bounded number of times', () => {
  const audit = readFileSync(new URL('../../JourneyTests/Audit.swift', import.meta.url), 'utf8');
  const limit = Number(/static let lostElementRetryLimit = (\d+)/.exec(audit)[1]);
  assert.ok(limit >= 1 && limit <= 2, `Audit.swift runs an audit again ${limit} times for an issue with no element`);
  assert.match(audit, /reportRetry\(audited, at: "lost-element-retries"\)/);
});

test('a journey runs an audit again only when every issue has no element, so a retry never hides an issue with one', () => {
  const audit = readFileSync(new URL('../../JourneyTests/Audit.swift', import.meta.url), 'utf8');
  // The one guard that decides a retry. An audit that reports an issue with an element, beside one with none, fails
  // at once: a second audit that missed the first issue would pass the screen and leave it only in the log.
  const guards = audit.match(/if [^\n]*lostRetries < lostElementRetryLimit[^\n]*/g) ?? [];
  assert.equal(guards.length, 1, 'Audit.swift has one guard for the retry of an issue with no element');
  assert.match(guards[0], /^if lostElements > 0, lostElements == issues\.count, lostRetries < lostElementRetryLimit \{$/);
});

test('the settings helper remembers each audit that ran again for text called partially unsupported, apart from the others', async (t) => {
  const { applier, ran } = fakeSimulator();
  const helper = await startSettingsHelper((setting, options) => applier.apply(setting, options));
  t.after(() => helper.close());
  const post = (body, method = 'POST') => fetch(`${helper.address}/partly-scaling-retries`, { method, body });
  assert.deepEqual(helper.partlyScalingRetries(), []);
  assert.equal((await post('the add form, in the largest text size')).status, 204);
  assert.deepEqual(helper.partlyScalingRetries(), ['the add form, in the largest text size']);
  // An audit with no name, or a request that isn't a POST, is not a retry.
  assert.equal((await post('')).status, 400);
  assert.equal((await post(undefined, 'GET')).status, 404);
  assert.equal(helper.partlyScalingRetries().length, 1);
  // It is not another flake's retry, changes no setting, and is not a screen.
  assert.deepEqual(helper.auditRetries(), []);
  assert.deepEqual(helper.lostElementRetries(), []);
  assert.deepEqual(ran, []);
  assert.deepEqual(helper.screens(), []);
});

test('the line after the journeys names each audit run again for text called partially unsupported, and the flake', () => {
  assert.deepEqual(partlyScalingRetryLines([]), []);
  assert.deepEqual(partlyScalingRetryLines(['the add form, in the largest text size']), [
    `  The journeys ran 1 audit again, because the Dynamic Type check called text partially unsupported (the named flake "${partlyScalingFlake}"):`,
    '    the add form, in the largest text size.',
  ]);
  assert.match(partlyScalingRetryLines(['a', 'b'])[0], /ran 2 audits again/);
});

test('a journey runs an audit again for text called partially unsupported a bounded number of times, on a still screen', () => {
  const audit = readFileSync(new URL('../../JourneyTests/Audit.swift', import.meta.url), 'utf8');
  const limit = Number(/static let partlyScalingRetryLimit = (\d+)/.exec(audit)[1]);
  assert.ok(limit >= 1 && limit <= 2, `Audit.swift runs an audit again ${limit} times for text called partially unsupported`);
  assert.match(audit, /reportRetry\(audited, at: "partly-scaling-retries"\)/);
  // Each try waits for a still screen first.
  assert.match(audit, /reportRetry\(audited, at: "partly-scaling-retries"\)\n.*Task\.sleep\(for: auditRetryPause\)\n.*stillScreen\(of: app, screen, in: setting\)/);
});

test('a journey runs an audit again for text called partially unsupported only when that is every issue, so a retry never hides another', () => {
  const audit = readFileSync(new URL('../../JourneyTests/Audit.swift', import.meta.url), 'utf8');
  const guards = audit.match(/if [^\n]*partlyScalingRetries < partlyScalingRetryLimit[^\n]*/g) ?? [];
  assert.equal(guards.length, 1, 'Audit.swift has one guard for the retry of text called partially unsupported');
  assert.match(guards[0], /^if partlyScaling > 0, partlyScaling == issues\.count, partlyScalingRetries < partlyScalingRetryLimit \{$/);
  // Only a Dynamic Type issue with XCTest's exact words, and with its element, counts. An issue with no element is
  // the other flake's, so a mix of the two fails at once.
  assert.match(
    audit,
    /if element != nil, issue\.auditType == \.dynamicType, issue\.compactDescription == partlyScalingWords \{\n\s*partlyScaling \+= 1/,
  );
  assert.match(audit, /static let partlyScalingWords = "Dynamic Type font sizes are partially unsupported"/);
});

test("an audit's failure says how many tries in a row had only one kind of issue, and counts only those", () => {
  const audit = readFileSync(new URL('../../JourneyTests/Audit.swift', import.meta.url), 'utf8');
  // Each try sets both counts: one more after a try whose every issue was of that kind, and none after any other.
  // So a try of the other kind, or a mix, starts the count again.
  assert.match(
    audit,
    /\n\s*onlyLostInARow = lostElements > 0 && lostElements == issues\.count \? onlyLostInARow \+ 1 : 0\n/,
  );
  assert.match(
    audit,
    /\n\s*onlyPartlyScalingInARow = partlyScaling > 0 && partlyScaling == issues\.count \? onlyPartlyScalingInARow \+ 1 : 0\n/,
  );
  // Each "times in a row" of the two retries comes from its own count, and only above one: never from a count of
  // retries, which also counts the tries of the other kind.
  const inARow = [...audit.matchAll(/\\\((\w+)(?: \+ 1)?\) times in a row/g)].map((match) => match[0]);
  assert.ok(inARow.includes('\\(onlyLostInARow) times in a row'), 'the failure counts tries with only lost elements');
  assert.ok(inARow.includes('\\(onlyPartlyScalingInARow) times in a row'), 'the failure counts tries with only partly scaling text');
  assert.ok(!inARow.some((words) => /lostRetries|partlyScalingRetries/.test(words)), `Audit.swift counts retries: ${inARow}`);
  assert.match(audit, /onlyLostInARow > 1\n\s*\? " The audit named an element/);
  assert.match(audit, /onlyPartlyScalingInARow > 1\n\s*\? " The audit called the text partially unsupported/);
});

test("each audit's retry puts the issues that caused it in the log", () => {
  const audit = readFileSync(new URL('../../JourneyTests/Audit.swift', import.meta.url), 'utf8');
  for (const words of ['named an element that was gone from the screen', 'called only text that scales partially unsupported']) {
    const line = new RegExp(`"The audit of \\\\\\(audited\\) ${words}\\. It runs again "\\n\\s*\\+ "\\([^\\n]*\\)\\. Its issues: \\\\\\(issues\\.joined\\(separator: "; "\\)\\)"\\)`);
    assert.match(audit, line, `the retry for "${words}" logs its issues`);
  }
});

test('a journey with no settings helper audits a still screen, not one still on its way in', () => {
  const audit = readFileSync(new URL('../../JourneyTests/Audit.swift', import.meta.url), 'utf8');
  const noHelper = /guard let helper else \{([\s\S]*?)\n    \}/.exec(audit)[1];
  assert.match(noHelper, /let shown = try await stillScreen\(of: app, screen, in: ownSetting\)\n\s*try await audit\(/);
});

test('the settings helper remembers each screenshot that was asked for again, apart from the audits', async (t) => {
  const { applier, ran } = fakeSimulator();
  const helper = await startSettingsHelper((setting, options) => applier.apply(setting, options));
  t.after(() => helper.close());
  const post = (body, method = 'POST') => fetch(`${helper.address}/screenshot-retries`, { method, body });
  assert.deepEqual(helper.screenshotRetries(), []);
  assert.equal((await post('the Add screen, in the default settings')).status, 204);
  assert.equal((await post('Home, in dark mode')).status, 204);
  assert.deepEqual(helper.screenshotRetries(), ['the Add screen, in the default settings', 'Home, in dark mode']);
  // A screenshot with no name, or a request that isn't a POST, is not a retry.
  assert.equal((await post('')).status, 400);
  assert.equal((await post(undefined, 'GET')).status, 404);
  assert.equal(helper.screenshotRetries().length, 2);
  // A screenshot asked for again is not an audit that ran again, changes no setting, and is not a screen.
  assert.deepEqual(helper.auditRetries(), []);
  assert.deepEqual(ran, []);
  assert.deepEqual(helper.screens(), []);
});

test('the line after the journeys names each screenshot asked for again, and the flake, and there is none when none was', () => {
  assert.deepEqual(screenshotRetryLines([]), []);
  assert.deepEqual(screenshotRetryLines(['the Add screen, in the default settings']), [
    `  The journeys asked for 1 screenshot again, because XCTest didn't get it in time (the named flake "${screenshotTimeOutFlake}"):`,
    '    the Add screen, in the default settings.',
  ]);
  assert.match(screenshotRetryLines(['a', 'b'])[0], /asked for 2 screenshots again/);
});

test("a journey asks for a timed-out screenshot again a bounded number of times, and only on XCTest's time-out", () => {
  const journeys = new URL('../../JourneyTests/', import.meta.url);
  const screenshot = readFileSync(new URL('Screenshot.swift', journeys), 'utf8');
  const limit = Number(/static let retryLimit = (\d+)/.exec(screenshot)[1]);
  assert.ok(limit >= 1 && limit <= 2, `Screenshot.swift asks for a timed-out screenshot again ${limit} times`);
  assert.match(screenshot, /static let timeOutWords = "Failed to get screenshot: Timed out"/);
  // The journey reports each retry at the path that the helper reads.
  assert.match(screenshot, /helper\.appending\(path: "screenshot-retries"\)/);
  // Every screenshot that a journey reads goes through the retry, and every journey's test case holds the
  // time-out back, so XCTest's issue doesn't fail the journey before the retry.
  const files = readdirSync(journeys).filter((file) => file.endsWith('.swift') && file !== 'Screenshot.swift');
  assert.ok(files.includes('Audit.swift') && files.includes('SignInJourney.swift'));
  for (const file of files) {
    const source = readFileSync(new URL(file, journeys), 'utf8');
    assert.doesNotMatch(source, /\.screenshot\(\)/, `${file} asks XCTest for a screenshot with no retry`);
    assert.doesNotMatch(source, /class \w+: XCTestCase\b/, `${file} has a test case that doesn't hold the time-out back`);
  }
});

test("the settings applier reads each option back, and says which it couldn't read", async () => {
  const { applier } = fakeSimulator();
  await applier.apply(settings[1]);
  assert.equal(await applier.read(), 'appearance light, increase_contrast disabled, content_size accessibility-extra-extra-extra-large');
  const failing = settingsApplier('SIM', {
    run: async (command) => {
      if (command[2] === 'appearance') throw new Error('No devices are booted.');
      return 'enabled\n';
    },
  });
  assert.equal(await failing.read(), 'appearance unread, increase_contrast enabled, content_size enabled');
  assert.equal(failing.calls(), 0, 'a read is not a call that changes a setting');
});

test('the line after the journeys names each change that was sent again, and the flake, and there is none when none was', () => {
  assert.deepEqual(resendLines([]), []);
  assert.deepEqual(resendLines([{ setting: 'dark mode', after: 'the default settings', read: 'appearance dark, increase_contrast disabled, content_size large' }]), [
    `  The journeys sent 1 change of setting again, because the app went on showing the screen as it was (the named flake "${resendFlake}"):`,
    '    the default settings to dark mode. The simulator read: appearance dark, increase_contrast disabled, content_size large.',
  ]);
  assert.match(resendLines([{}, {}])[0], /sent 2 changes of setting again/);
});

test("CI uploads the gate's files after a pass too, when a first try was kept, from each Gate job that runs steps", (t) => {
  const ci = readFileSync(new URL('../../.github/workflows/ci.yml', import.meta.url), 'utf8');
  // The patterns match the names that keepFirstTry gives.
  const directory = mkdtempSync(path.join(tmpdir(), 'wishbone-gate-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const [bundle, log] = keepFirstTry(directory, path.join(directory, 'journeys-settings.xcresult'), 'journeys-settings.log')
    .map((kept) => path.basename(kept).replace(/^journeys-settings/, ''));
  for (const job of ['gate-build', 'gate-journeys']) {
    const start = ci.indexOf(`\n  ${job}:\n`);
    assert.ok(start >= 0, `the workflow has the job ${job}`);
    const body = ci.slice(start + 1, ci.indexOf('\n  gate-', start + 1) === -1 ? undefined : ci.indexOf('\n  gate-', start + 1));
    const upload = /^\s+- if: (failure\(\).+)\n\s+uses: actions\/upload-artifact@/m.exec(body);
    assert.ok(upload, `${job} has an upload step on a failure`);
    const condition = upload[1];
    assert.match(condition, /^failure\(\) \|\| hashFiles\(/, 'the upload runs on a failure, or when a first try was kept');
    assert.ok(condition.includes(`'build/gate/**/*${log}'`), `${condition} has no pattern for *${log}`);
    assert.ok(condition.includes(`'build/gate/**/*${bundle}/**'`), `${condition} has no pattern for *${bundle}`);
  }
});

/** The error that `simctl ui` gave on CI when the simulator had shut down by itself (run 45151826388). */
const shutDown = () =>
  new Error(
    "simctl ui SIM appearance light An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=405):\nUnable to lookup in current state: Shutdown, so the simulator isn't in the default settings",
  );

/** The step's start, with each part a fake that records itself and fails as `fails(part, tries)` says. */
function fakeStart(fails = () => null) {
  const parts = [];
  const lines = [];
  const kept = [];
  const part = (name) => async () => {
    parts.push(name);
    const error = fails(name, parts.filter((one) => one === name).length);
    if (error) throw error;
    return name === 'default' ? 'applier' : undefined;
  };
  const start = () =>
    startSimulator({
      boot: part('boot'),
      hold: part('hold'),
      putInDefault: part('default'),
      keepLogs: (sighting) => {
        kept.push(sighting);
        return `build/gate/run/simulator/simulator-start-${sighting}-first.log`;
      },
      say: (line) => lines.push(line),
    });
  return { start, parts, lines, kept };
}

test("the step's start boots the simulator, holds its status bar, and puts it in the default settings, once", async () => {
  const { start, parts, lines, kept } = fakeStart();
  assert.equal(await start(), 'applier');
  assert.deepEqual(parts, ['boot', 'hold', 'default']);
  assert.equal(lines.length, 3);
  assert.deepEqual(kept, []);
});

test('a simulator that shuts down by itself at the step\'s start boots again, keeps its logs, and the start passes', async () => {
  const { start, parts, lines, kept } = fakeStart((part, tries) => (part === 'default' && tries === 1 ? shutDown() : null));
  assert.equal(await start(), 'applier');
  assert.deepEqual(parts, ['boot', 'hold', 'default', 'boot', 'hold', 'default']);
  assert.deepEqual(kept, [1]);
  const line = lines.find((one) => one.includes(shutdownFlake));
  assert.ok(line, `no line names the flake: ${lines.join('\n')}`);
  assert.match(line, /boots again \(1 of 2\)/);
  assert.match(line, /simulator-start-1-first\.log/);
  assert.match(line, /Unable to lookup in current state: Shutdown/);
});

test('a simulator that shuts down while its status bar is held boots again too', async () => {
  const { start, parts } = fakeStart((part, tries) => (part === 'hold' && tries === 1 ? shutDown() : null));
  assert.equal(await start(), 'applier');
  assert.deepEqual(parts, ['boot', 'hold', 'boot', 'hold', 'default']);
});

test('the simulator boots again at most twice: a third shutdown at the start is red', async () => {
  const { start, parts, kept } = fakeStart((part) => (part === 'default' ? shutDown() : null));
  await assert.rejects(start(), /current state: Shutdown/);
  assert.equal(parts.filter((part) => part === 'boot').length, 1 + startReboots);
  assert.equal(startReboots, 2);
  assert.deepEqual(kept, [1, 2, 3]);
});

test("a failure at the step's start that isn't a shutdown is red at once", async () => {
  const { start, parts, kept } = fakeStart((part) => (part === 'default' ? new Error('simctl ui SIM appearance light didn\'t return within 5m00s, twice in 10m00s') : null));
  await assert.rejects(start(), /didn't return/);
  assert.deepEqual(parts, ['boot', 'hold', 'default']);
  assert.deepEqual(kept, []);
});

test("the shutdown's signature is CoreSimulator's error for a device that is shut down, and nothing else", () => {
  assert.equal(shutDownBySelf(shutDown()), true);
  // execFileSync's error, as the status bar's override gives it.
  assert.equal(shutDownBySelf(new Error('Command failed: xcrun simctl status_bar SIM override\nUnable to lookup in current state: Shutdown')), true);
  assert.equal(shutDownBySelf(new Error('No devices are booted.')), false);
  assert.equal(shutDownBySelf(new Error('Invalid device state')), false);
  assert.equal(shutDownBySelf(Object.assign(new Error("didn't return within 30s"), { timedOut: true })), false);
});

test("the simulator's logs at a shutdown go where CI uploads a first try, and a log that isn't there is named", (t) => {
  const directory = mkdtempSync(path.join(tmpdir(), 'wishbone-gate-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const logs = path.join(directory, 'CoreSimulator');
  mkdirSync(path.join(logs, 'SIM'), { recursive: true });
  writeFileSync(path.join(logs, 'CoreSimulator.log'), `${'old line\n'.repeat(10)}SIM state Booted -> Shutdown\n`);
  const results = path.join(directory, 'results');
  mkdirSync(results);

  const kept = keepStartLogs({ directory: results, simulator: 'SIM', sighting: 1, logs, limitBytes: 40 });
  assert.equal(kept, path.join(results, 'simulator-start-1-first.log'));
  // The upload step's condition has the pattern `build/gate/**/*-first.log`.
  assert.match(path.basename(kept), /-first\.log$/);
  const text = readFileSync(kept, 'utf8');
  assert.match(text, /SIM state Booted -> Shutdown/);
  assert.ok(!text.includes('old line\nold line\nold line\nold line\nold line'), 'it keeps only the end of a long log');
  assert.match(text, /system\.log: not there/);
});
