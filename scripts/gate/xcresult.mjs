// Reads the results of a simulator test run from Xcode's result bundles, and judges them.
//
// A result bundle (`.xcresult`) holds every test of one `xcodebuild` run: Swift Testing's and XCTest's. Xcode's
// own `xcresulttool` prints them as a tree, and the gate reads that tree, not the text on the terminal.

import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';

import { judge } from './reading.mjs';

/** A reading of a bundle that can't be read: the run has no summary. */
const unreadable = { tests: null, runFailed: null, failed: [], known: [], skipped: [], strayIssues: 0, summary: null, names: [] };

/**
 * Reads the tree that `xcresulttool get test-results tests` prints, as an object.
 *
 * Returns a reading in the shape that `judge` takes: `{ tests, runFailed, failed, known, skipped, strayIssues,
 * summary }`, with `names`, the name of every test. A test's name is `Bundle.Suite/function()`. A test with
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
  const visit = (node, bundle) => {
    if (typeof node.nodeType === 'string' && node.nodeType.endsWith('test bundle')) bundle = node.name;
    if (node.nodeType === 'Test Case') {
      const name = `${bundle}.${node.nodeIdentifier ?? node.name}`;
      names.push(name);
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
