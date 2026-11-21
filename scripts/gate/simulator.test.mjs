import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

import {
  buildArguments,
  compiledFiles,
  gateSimulators,
  helperAnswerLimitMs,
  journeyRuns,
  parseArguments,
  pickDevice,
  resultBundles,
  settingCallLimitMs,
  settingCommands,
  settings,
  settingsApplier,
  simctlWithLimit,
  startSettingsHelper,
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
  assert.equal(applier.retries(), 0);
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

test('a simctl call that hangs is run once more, and the applier counts it', async () => {
  const ran = [];
  const applier = settingsApplier('SIM', {
    run: async (command, limitMs) => {
      assert.equal(limitMs, 30_000);
      ran.push(command[3]);
      if (command[3] === 'dark' && ran.filter((value) => value === 'dark').length === 1) throw hung();
    },
  });
  await applier.apply(settings[0]);
  await applier.apply(settings[2]);
  assert.deepEqual(ran.slice(3), ['dark', 'dark']);
  assert.equal(applier.calls(), 5);
  assert.equal(applier.retries(), 1);
});

test("an apply can give its calls a longer limit, as the step's start does while the simulator gets ready", async () => {
  const limits = [];
  const applier = settingsApplier('SIM', { run: async (command, limitMs) => limits.push(limitMs) });
  await applier.apply(settings[0], { limitMs: 300_000 });
  await applier.apply(settings[1]);
  assert.deepEqual(limits, [300_000, 300_000, 300_000, 30_000]);
});

test('a simctl call that hangs twice fails the setting, with the setting and the call in the error', async () => {
  const applier = settingsApplier('SIM', {
    run: async (command) => {
      if (command[2] === 'content_size' && command[3] !== 'large') throw hung();
    },
  });
  await applier.apply(settings[0]);
  await assert.rejects(applier.apply(settings[1]), {
    message: "simctl ui SIM content_size accessibility-extra-extra-extra-large didn't return within 30s, twice, so the simulator isn't in the largest text size",
  });
  assert.equal(applier.retries(), 1);
});

test('a call that passes its limit is stopped, and its error says it timed out', async () => {
  const started = Date.now();
  await assert.rejects(simctlWithLimit(['30'], 200, { file: 'sleep', prefix: [] }), (error) => error.timedOut === true && /didn't return within 0s/.test(error.message));
  assert.ok(Date.now() - started < 5000, 'the call was stopped at its limit');
  await assert.rejects(simctlWithLimit(['-c', 'echo "No devices are booted." >&2; exit 1'], 5000, { file: 'sh', prefix: [] }), (error) => error.timedOut === false && error.message === 'No devices are booted.');
  assert.equal(await simctlWithLimit(['-c', 'echo ok'], 5000, { file: 'sh', prefix: [] }), 'ok\n');
});

test('the settings helper answers 500, with the reason, when a hung call fails a setting', async (t) => {
  const applier = settingsApplier('SIM', { run: async () => Promise.reject(hung()) });
  const helper = await startSettingsHelper((setting) => applier.apply(setting));
  t.after(() => helper.close());
  const response = await fetch(`${helper.address}/settings/default`, { method: 'POST' });
  assert.equal(response.status, 500);
  assert.equal(await response.text(), "simctl ui SIM appearance light didn't return within 30s, twice, so the simulator isn't in the default settings");
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

test("a journey waits for the helper longer than the helper's longest answer: each call of an apply hung once, and then hung again", () => {
  const audit = readFileSync(new URL('../../JourneyTests/Audit.swift', import.meta.url), 'utf8');
  const seconds = Number(/static let helperTimeout: TimeInterval = (\d+)/.exec(audit)[1]);
  assert.ok(seconds * 1000 > helperAnswerLimitMs, `Audit.swift waits ${seconds}s, and the helper can take ${helperAnswerLimitMs / 1000}s`);
  assert.equal(helperAnswerLimitMs, settingCommands(settings[0], 'SIM').length * 2 * settingCallLimitMs);
});
