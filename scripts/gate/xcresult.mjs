// Reads the results of a simulator test run from Xcode's result bundles, and judges them.
//
// A result bundle (`.xcresult`) holds every test of one `xcodebuild` run: Swift Testing's and XCTest's. Xcode's
// own `xcresulttool` prints them as a tree, and the gate reads that tree, not the text on the terminal.

import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';

import { judge } from './reading.mjs';

/** A reading of a bundle that can't be read: the run has no summary. */
const unreadable = { tests: null, runFailed: null, failed: [], known: [], skipped: [], strayIssues: 0, summary: null, names: [], testsMs: null };

/**
 * Reads the tree that `xcresulttool get test-results tests` prints, as an object.
 *
 * Returns a reading in the shape that `judge` takes: `{ tests, runFailed, failed, known, skipped, strayIssues,
 * summary }`, with `names`, the name of every test, and `testsMs`, the time that the tests took, without what
 * Xcode does around them, such as installing and launching the test runner. A test's name is `Bundle.Suite/function()`. A test with
 * arguments is one test. A test that passes with an expected failure (`XCTExpectFailure`, `withKnownIssue`) is
 * `known`. `tests` is null when the tree is not one of a test run.
 */
export function readTestResults(results) {
  const plans = results?.testNodes;
  if (!Array.isArray(plans)) return unreadable;
  const names = [];
  const failed = [];
  const known = [];
  const skipped = [];
  let testsMs = 0;
  const visit = (node, bundle) => {
    if (typeof node.nodeType === 'string' && node.nodeType.endsWith('test bundle')) bundle = node.name;
    if (node.nodeType === 'Test Case') {
      const name = `${bundle}.${node.nodeIdentifier ?? node.name}`;
      names.push(name);
      testsMs += Math.round((node.durationInSeconds ?? 0) * 1000);
      if (node.result === 'Expected Failure') known.push(name);
      else if (node.result === 'Skipped') skipped.push(name);
      // Any other result that is not a pass is a failure, so a result that Xcode adds later can't pass by default.
      else if (node.result !== 'Passed') failed.push(name);
      return;
    }
    for (const child of node.children ?? []) visit(child, bundle);
  };
  for (const plan of plans) visit(plan, 'Tests');
  // Xcode can fail a run in which no test failed, for example when the app crashes between two tests.
  const runFailed = plans.some((plan) => plan.result === 'Failed');
  return {
    tests: names.length,
    runFailed,
    failed: failed.sort(),
    known: known.sort(),
    skipped: skipped.sort(),
    strayIssues: 0,
    summary: runFailed ? 'Xcode says that the run failed' : 'Xcode says that the run passed',
    names: names.sort(),
    testsMs,
  };
}

/** Reads the result bundle at `bundle`. A bundle that is missing, or that `xcresulttool` can't read, has no summary. */
export function readResultBundle(bundle) {
  if (!existsSync(bundle)) return unreadable;
  try {
    const printed = execFileSync('xcrun', ['xcresulttool', 'get', 'test-results', 'tests', '--path', bundle], {
      encoding: 'utf8',
      maxBuffer: 256 * 1024 * 1024,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    return readTestResults(JSON.parse(printed));
  } catch {
    return unreadable;
  }
}

/**
 * The `check` of a step that runs tests in the simulator.
 *
 * `tiers` maps the name of a count, such as `hosted`, to the result bundles of that tier: `[{ path, label }]`.
 * The bundles of one tier hold the same tests, each run in another setting. So the tier's count is the count of
 * one bundle, and every bundle must hold the same tests.
 *
 * Returns the reason why the step fails, if it does, and the counts.
 */
export function checkResultBundles(tiers, { exit, allowedSkips = [], read = readResultBundle }) {
  const counts = {};
  for (const [countName, bundles] of Object.entries(tiers)) {
    let first = null;
    for (const bundle of bundles) {
      const reading = read(bundle.path);
      // With no summary, the tests didn't run to the end: the build failed, or the run died. The step's exit code
      // and its log say which. A step that says it passed with no summary fails here.
      if (reading.tests === null) return exit === 0 ? { fail: `${bundle.label}: ${judge(reading)}`, counts } : { counts };
      const problem = judge(reading, allowedSkips);
      if (problem !== null) return { fail: `${bundle.label}: ${problem}`, counts };
      first ??= reading;
      if (reading.names.join('\n') !== first.names.join('\n')) {
        return { fail: `${bundle.label}: it ran other tests than ${bundles[0].label}`, counts };
      }
      counts[countName] = reading.tests;
    }
  }
  return { counts };
}

/** The name of every attachment in what `xcresulttool get test-results activities` prints for one test, in order. */
export function attachmentNames(activities) {
  const names = [];
  const visit = (activity) => {
    for (const attachment of activity.attachments ?? []) names.push(attachment.name);
    for (const child of activity.childActivities ?? []) visit(child);
  };
  for (const run of activities?.testRuns ?? []) for (const activity of run.activities ?? []) visit(activity);
  return names;
}

/** The names of the attachments of every test in the result bundle at `bundle`. */
export function readAttachmentNames(bundle) {
  const tests = readResultBundle(bundle).names;
  return tests.flatMap((name) => {
    // A name is `Bundle.Suite/function()`, and `xcresulttool` knows the test as `Suite/function()`.
    const printed = execFileSync('xcrun', ['xcresulttool', 'get', 'test-results', 'activities', '--path', bundle, '--test-id', name.slice(name.indexOf('.') + 1)], {
      encoding: 'utf8',
      maxBuffer: 256 * 1024 * 1024,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    return attachmentNames(JSON.parse(printed));
  });
}

/**
 * Checks the audit's screenshots in the result bundle of the journeys in the four settings. The journeys attach a
 * screenshot of each screen that they audit, in each setting, named `<screen>, in <setting's label>`, and Xcode
 * adds its own ending to each name. Each screen that the run reached must be audited in each setting once: a
 * later journey that reaches a screen again doesn't audit it again. Other attachments don't count.
 *
 * `audited` is the names of the screens that the settings helper answered 201 for: the screens that the run
 * audited. The bundle's screens must be exactly those. So a name that the check can't read, a label in
 * `Audit.swift` that differs from the gate's, or a screen with none of its screenshots fails, and doesn't pass as
 * a run that audited fewer screens.
 *
 * Returns `{ screens, problem }`: the number of screens in the bundle, and what is wrong, or null.
 */
export function checkAuditScreenshots(names, labels, audited) {
  const screens = new Map();
  for (const attached of names) {
    const name = attached.replace(/_\d+_[0-9A-Za-z-]+\.[a-z]+$/, '');
    const label = labels.find((one) => name.endsWith(`, in ${one}`));
    if (label === undefined) continue;
    const screen = name.slice(0, -`, in ${label}`.length);
    if (!screens.has(screen)) screens.set(screen, new Map(labels.map((one) => [one, 0])));
    screens.get(screen).set(label, screens.get(screen).get(label) + 1);
  }
  for (const [screen, counts] of screens) {
    if ([...counts.values()].some((count) => count > 1)) {
      const times = [...counts].filter(([, count]) => count > 1).map(([label, count]) => `${count} times in ${label}`);
      return { screens: screens.size, problem: `${screen} was audited more than once in the run: ${times.join(', ')}` };
    }
    const missing = [...counts].filter(([, count]) => count === 0).map(([label]) => label);
    if (missing.length > 0) return { screens: screens.size, problem: `${screen} was not audited in ${missing.join(', ')}` };
  }
  const absent = audited.filter((screen) => !screens.has(screen));
  if (absent.length > 0) return { screens: screens.size, problem: `the result bundle has no screenshot of ${absent.join(', ')}, which the settings helper audited` };
  const extra = [...screens.keys()].filter((screen) => !audited.includes(screen));
  if (extra.length > 0) {
    return { screens: screens.size, problem: `the result bundle has screenshots of ${extra.join(', ')}, which the settings helper did not audit` };
  }
  return { screens: screens.size, problem: null };
}
