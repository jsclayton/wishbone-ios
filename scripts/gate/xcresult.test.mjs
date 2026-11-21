import assert from 'node:assert/strict';
import { test } from 'node:test';

import { judge } from './reading.mjs';
import { testResults } from './xcresult-fixture.mjs';
import { checkResultBundles, readResultBundle, readTestResults } from './xcresult.mjs';

const item = 'HostedTests.SessionKeychainTests/item()';
const signIn = 'JourneyTests.SignInJourney/testSignIn()';

test('a result bundle that passes gives its count, and nothing to fail on', () => {
  const reading = readTestResults(testResults({ [item]: 'pass', 'HostedTests.PaletteTests/contrast(color:)': 'pass' }));
  assert.equal(reading.tests, 2);
  assert.deepEqual(reading.names, ['HostedTests.PaletteTests/contrast(color:)', item]);
  assert.equal(judge(reading), null);
});

test('a failing test fails, by name, with its bundle', () => {
  const reading = readTestResults(testResults({ [item]: 'pass', [signIn]: 'fail' }));
  assert.equal(reading.tests, 2);
  assert.equal(judge(reading), `1 failed: ${signIn}`);
});

test('a test with arguments is one test, and one failing case fails it', () => {
  const reading = readTestResults(testResults({ 'HostedTests.PaletteTests/contrast(color:)': 'fail-case', [item]: 'pass' }));
  assert.equal(reading.tests, 2);
  assert.equal(judge(reading), '1 failed: HostedTests.PaletteTests/contrast(color:)');
});

test('an expected failure is a known issue, and fails', () => {
  const reading = readTestResults(testResults({ [item]: 'known' }));
  assert.equal(judge(reading), `1 with a known issue: ${item}`);
});

test('a skipped test fails unless it is on the named list', () => {
  const reading = readTestResults(testResults({ [item]: 'pass', [signIn]: 'skip' }));
  assert.equal(reading.tests, 2);
  assert.equal(judge(reading), `1 skipped, and not on the named list: ${signIn}`);
  assert.equal(judge(reading, [signIn]), null);
});

test('a result that the gate does not know is a failure', () => {
  const results = testResults({ [item]: 'pass' });
  results.testNodes[0].children[0].children[0].children[0].result = 'Mixed';
  assert.equal(judge(readTestResults(results)), `1 failed: ${item}`);
});

test('a run that Xcode fails with no failing test fails', () => {
  const reading = readTestResults(testResults({ [item]: 'pass' }, { runFailed: true }));
  assert.equal(judge(reading), 'the test run failed: Xcode says that the run failed');
});

test('a bundle with 0 tests fails', () => {
  assert.equal(judge(readTestResults(testResults({}))), '0 tests ran');
});

test('what is not the tree of a test run has no summary', () => {
  for (const results of [undefined, null, {}, { testNodes: 'none' }]) {
    assert.equal(judge(readTestResults(results)), 'the test run has no summary');
  }
});

test('a bundle that is missing has no summary', () => {
  assert.equal(readResultBundle('/nowhere/missing.xcresult').tests, null);
});

/** A check of bundles that are in memory: `bundles` maps a bundle's path to its tree. */
function check(tiers, bundles, options = {}) {
  return checkResultBundles(tiers, { exit: 0, ...options, read: (path) => readTestResults(bundles[path]) });
}

const tiers = {
  hosted: [{ path: 'hosted', label: 'the hosted tests' }],
  ui: [
    { path: 'default', label: 'the journeys' },
    { path: 'dark', label: 'the journeys in dark mode' },
  ],
};

test('the check gives a count for each tier: the tests of one bundle, not the sum of its settings', () => {
  const bundles = { hosted: testResults({ [item]: 'pass' }), default: testResults({ [signIn]: 'pass' }), dark: testResults({ [signIn]: 'pass' }) };
  assert.deepEqual(check(tiers, bundles), { counts: { hosted: 1, ui: 1 } });
});

test('the check names the bundle that fails', () => {
  const bundles = { hosted: testResults({ [item]: 'pass' }), default: testResults({ [signIn]: 'pass' }), dark: testResults({ [signIn]: 'fail' }) };
  assert.deepEqual(check(tiers, bundles), { fail: `the journeys in dark mode: 1 failed: ${signIn}`, counts: { hosted: 1, ui: 1 } });
});

test('the check fails when a setting ran other tests', () => {
  const bundles = {
    hosted: testResults({ [item]: 'pass' }),
    default: testResults({ [signIn]: 'pass', 'JourneyTests.SignOutJourney/testSignOut()': 'pass' }),
    dark: testResults({ [signIn]: 'pass' }),
  };
  assert.equal(check(tiers, bundles).fail, 'the journeys in dark mode: it ran other tests than the journeys');
});

test('a bundle that is missing fails a step that says it passed', () => {
  const bundles = { hosted: testResults({ [item]: 'pass' }), default: testResults({ [signIn]: 'pass' }) };
  assert.equal(check(tiers, bundles).fail, 'the journeys in dark mode: the test run has no summary');
});

test('a bundle that is missing leaves a step that failed to its exit code and its log', () => {
  assert.deepEqual(check(tiers, {}, { exit: 65 }), { counts: {} });
});

test('the check passes the named list of skips on', () => {
  const bundles = { hosted: testResults({ [item]: 'skip' }), default: testResults({ [signIn]: 'pass' }), dark: testResults({ [signIn]: 'pass' }) };
  assert.equal(check(tiers, bundles).fail, `the hosted tests: 1 skipped, and not on the named list: ${item}`);
  assert.equal(check(tiers, bundles, { allowedSkips: [item] }).fail, undefined);
});
