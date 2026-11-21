import assert from 'node:assert/strict';
import { test } from 'node:test';

import { gateSimulators, pickDevice, resultBundles, settings } from './simulator.mjs';

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

test('the journeys run in the four settings of the audit, and then in the double-length pseudo-language', () => {
  assert.deepEqual(settings.map((setting) => setting.name), ['default', 'largest-text', 'dark-mode', 'increase-contrast', 'double-length']);
  // The first setting is the default of each, so applying it puts the simulator back.
  assert.deepEqual(Object.keys(settings[0]), ['name', 'label']);
});

test('a run has one result bundle for the hosted tests, and one for the journeys in each setting', () => {
  const bundles = resultBundles('/run/simulator');
  assert.deepEqual(bundles.hosted, [{ path: '/run/simulator/hosted.xcresult', label: 'the hosted tests' }]);
  assert.equal(bundles.ui.length, settings.length);
  assert.deepEqual(bundles.ui[2], { path: '/run/simulator/journeys-dark-mode.xcresult', label: 'the journeys in dark mode' });
});
