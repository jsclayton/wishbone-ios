import assert from 'node:assert/strict';
import { test } from 'node:test';

import { judge } from './reading.mjs';
import { testResults } from './xcresult-fixture.mjs';
import { attachmentNames, checkAuditScreenshots, checkResultBundles, readResultBundle, readTestResults } from './xcresult.mjs';

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

test("a failed test's failure messages are read, in order, also from a failing case", () => {
  const contrast = 'HostedTests.PaletteTests/contrast(color:)';
  const messages = { [signIn]: ['SignInJourney.swift:37: one', 'SignInJourney.swift:40: two'] };
  const reading = readTestResults(testResults({ [signIn]: 'fail', [contrast]: 'fail-case', [item]: 'pass' }, { messages }));
  assert.deepEqual(reading.messages, { [signIn]: ['SignInJourney.swift:37: one', 'SignInJourney.swift:40: two'], [contrast]: ['planted'] });
});

test('an expected failure is a known issue, and fails', () => {
  const reading = readTestResults(testResults({ [item]: 'known' }));
  assert.equal(judge(reading), `1 with a known issue: ${item} ("planted")`);
});

test("an expected failure's reasons are read, as XCTest gives them, and not the issue's message", () => {
  const reading = readTestResults(testResults({ [item]: 'known', [signIn]: 'pass' }, { reasons: { [item]: ['one', 'two'] } }));
  assert.deepEqual(reading.known, [item]);
  assert.deepEqual(reading.knownReasons, { [item]: ['one', 'two'] });
});

test('a known issue passes only in a test on the named list, and only with its reason', () => {
  const lag = "XCTest's record of an app's state lags on a CI runner";
  const allowed = [{ test: item, reason: lag }];
  const read = (reasons, outcomes = { [item]: 'known', [signIn]: 'pass' }) =>
    readTestResults(testResults(outcomes, { reasons }));
  // The named test, with the named reason, passes.
  assert.equal(judge(read({ [item]: [lag] }), [], allowed), null);
  // The same test with another reason fails, and so does one with the named reason and another too.
  assert.equal(judge(read({ [item]: ['something else'] }), [], allowed), `1 with a known issue: ${item} ("something else")`);
  assert.equal(judge(read({ [item]: [lag, 'something else'] }), [], allowed), `1 with a known issue: ${item} ("${lag}", "something else")`);
  // Another test with the named reason fails.
  const other = read({ [signIn]: [lag] }, { [item]: 'pass', [signIn]: 'known' });
  assert.equal(judge(other, [], allowed), `1 with a known issue: ${signIn} ("${lag}")`);
  // With no list, as before, every known issue fails.
  assert.equal(judge(read({ [item]: [lag] })), `1 with a known issue: ${item} ("${lag}")`);
  // A reading with no reasons, as from an event stream, fails even for the named test.
  assert.equal(judge({ ...read({ [item]: [lag] }), knownReasons: undefined }, [], allowed), `1 with a known issue: ${item}`);
  // A failure in the named test still fails.
  assert.match(judge(read({}, { [item]: 'fail', [signIn]: 'pass' }), [], allowed), /^1 failed: /);
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
  assert.deepEqual(check(tiers, bundles), { counts: { hosted: 1, ui: 1 }, names: { hosted: [item], ui: [signIn] } });
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

test("a reading holds the time that its tests took, without Xcode's own time around them", () => {
  assert.equal(readTestResults(testResults({ [item]: 'pass', [signIn]: 'pass' })).testsMs, 3000);
  assert.equal(readTestResults({ testNodes: [] }).testsMs, 0);
  assert.equal(readTestResults({}).testsMs, null);
});

const labels = ['the default settings', 'the largest text size', 'dark mode', 'Increase Contrast'];
/** The names that Xcode gives the screenshots of a screen in each setting, with its own ending on each. */
const shots = (screen, settings = labels) => settings.map((label, index) => `${screen}, in ${label}_0_5C9AA6C6-40DD-4147-A856-75E87376AF${String(index).padStart(2, '0')}.png`);

test('the result bundle passes when it has each screen that the journeys reached in the four settings, once', () => {
  const names = [...shots('the signed-out screen'), ...shots('Home'), 'Kite, the screenshot of a failure_0_1.png', ...shots('Lists')];
  assert.deepEqual(checkAuditScreenshots(names, labels, ['the signed-out screen', 'Home', 'Lists']), { screens: 3, problem: null });
});

test('the result bundle fails when the settings helper audited no screen', () => {
  // The journeys didn't reach the helper, so each audited once in the simulator's own settings.
  const problem = "the settings helper audited no screen, so the journeys didn't reach it";
  assert.deepEqual(checkAuditScreenshots([], labels, []), { screens: 0, problem });
  assert.deepEqual(checkAuditScreenshots(shots('Home'), labels, []), { screens: 1, problem });
});

test('the result bundle fails when it has fewer screens than the settings helper audited', () => {
  const names = [...shots('the signed-out screen'), ...shots('Home')];
  assert.deepEqual(checkAuditScreenshots(names, labels, ['the signed-out screen', 'Home', 'Lists']), {
    screens: 2,
    problem: 'the result bundle has no screenshot of Lists, which the settings helper audited',
  });
  assert.deepEqual(checkAuditScreenshots([], labels, ['Home']), {
    screens: 0,
    problem: 'the result bundle has no screenshot of Home, which the settings helper audited',
  });
});

test("the result bundle fails when an audited screen's screenshots have names that the check can't read", () => {
  // A label in Audit.swift that drifted from the gate's own: the screenshots of Home name no setting that the gate knows.
  const names = [...shots('the signed-out screen'), ...shots('Home', ['the default settings', 'the biggest text', 'dark mode', 'Increase Contrast'])];
  assert.deepEqual(checkAuditScreenshots(names, labels, ['the signed-out screen', 'Home']), {
    screens: 2,
    problem: 'Home was not audited in the largest text size',
  });
  const unreadable = [...shots('the signed-out screen'), 'Home in dark mode_0_1.png'];
  assert.deepEqual(checkAuditScreenshots(unreadable, labels, ['the signed-out screen', 'Home']), {
    screens: 1,
    problem: 'the result bundle has no screenshot of Home, which the settings helper audited',
  });
});

test('the result bundle fails when it has a screen that the settings helper did not audit', () => {
  const names = [...shots('Home'), ...shots('Gifts')];
  assert.deepEqual(checkAuditScreenshots(names, labels, ['Home']), {
    screens: 2,
    problem: 'the result bundle has screenshots of Gifts, which the settings helper did not audit',
  });
});

test('the result bundle fails when a later journey audited a screen again', () => {
  const names = [...shots('the signed-out screen'), ...shots('Home'), ...shots('Home'), ...shots('Lists')];
  assert.deepEqual(checkAuditScreenshots(names, labels, ['the signed-out screen', 'Home', 'Lists']), {
    screens: 3,
    problem: 'Home was audited more than once in the run: 2 times in the default settings, 2 times in the largest text size, 2 times in dark mode, 2 times in Increase Contrast',
  });
});

test('the result bundle fails when a screen is not in all four settings', () => {
  const names = [...shots('Home'), ...shots('Gifts', ['the default settings', 'dark mode'])];
  assert.deepEqual(checkAuditScreenshots(names, labels, ['Home', 'Gifts']), { screens: 2, problem: 'Gifts was not audited in the largest text size, Increase Contrast' });
});

test("the screenshots' names are read from each test's activities, at any depth, in every run", () => {
  const activities = {
    testRuns: [
      {
        activities: [
          { title: 'Set Up' },
          { title: 'Audit', attachments: [{ name: 'Home, in dark mode_0_A.png' }], childActivities: [{ title: 'inner', attachments: [{ name: 'Lists, in dark mode_0_B.png' }] }] },
        ],
      },
      { activities: [{ title: 'again', attachments: [{ name: 'Gifts, in dark mode_0_C.png' }] }] },
    ],
  };
  assert.deepEqual(attachmentNames(activities), ['Home, in dark mode_0_A.png', 'Lists, in dark mode_0_B.png', 'Gifts, in dark mode_0_C.png']);
  assert.deepEqual(attachmentNames({}), []);
});
