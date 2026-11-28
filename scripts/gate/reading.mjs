// Reads the results of a test run, and judges them.
//
// The package's Swift Testing tests are read from Swift Testing's event stream (`--event-stream-output-path`,
// version 0), not from the text on the terminal: a test can print anything there.
//
// XCTest writes nothing but that text in `swift test` (its xUnit file, with `--parallel`, leaves out skips). So
// the package's XCTest tests are read from XCTest's own lines in the step's log. Each is a whole line in a fixed
// shape, and the count comes from the end of XCTest's run, which XCTest writes after every test has ended.

import { readFileSync } from 'node:fs';

/** A test's ID without its source location: `Module.Suite/function()`. */
function testName(id) {
  return id.replace(/\/[^/]+:\d+:\d+$/, '');
}

/**
 * Reads an event stream.
 *
 * `swift test` runs each test target in a process of its own, and each writes its run to the one stream. So a
 * stream can hold several runs, and the reading is of them all.
 *
 * Returns `{ tests, runFailed, failed, known, skipped, strayIssues, summary }`. `tests` is the sum of the counts
 * in Swift Testing's summaries, or null when a run has no summary: it didn't finish. `runFailed` says whether a
 * run's summary says that it failed, and `summary` is that summary, or else the last one. The lists hold test
 * names. `skipped` holds each test that was skipped, that cancelled itself, or that had a case cancelled.
 */
export function readEventStream(text) {
  const kinds = new Map();
  const failed = new Set();
  const known = new Set();
  const skipped = new Set();
  let strayIssues = 0;
  let started = 0;
  const summaries = [];

  for (const line of text.split('\n')) {
    if (line.trim() === '') continue;
    let record;
    try {
      record = JSON.parse(line);
    } catch {
      continue; // A run that died can leave half a line. It has no summary either, so it fails.
    }
    const payload = record.payload ?? {};
    if (record.kind === 'test') {
      kinds.set(payload.id, payload.kind);
      continue;
    }
    if (record.kind !== 'event') continue;
    switch (payload.kind) {
      case 'issueRecorded': {
        // A warning (`Issue.record(_:severity: .warning)`) is not a failure. Swift Testing 6.4 leaves it out of a
        // version 0 stream, and a later version that writes it puts its severity in the issue.
        const severity = payload.issue?._severity ?? payload.issue?.severity;
        if (severity === 'warning') break;
        const list = payload.issue?.isKnown === true ? known : failed;
        if (payload.testID === undefined) strayIssues += 1;
        else list.add(testName(payload.testID));
        break;
      }
      // A test that cancels itself (`Test.cancel`) is a skip from inside the test. In a parameterized test, the
      // call cancels one case, and the event names the test. Either way, some of the test didn't run.
      case 'testSkipped':
      case 'testCancelled':
      case 'testCaseCancelled':
        // A suite that is skipped reports each of its tests too.
        if (kinds.get(payload.testID) !== 'suite') skipped.add(testName(payload.testID));
        break;
      case 'runStarted':
        started += 1;
        break;
      case 'runEnded':
        summaries.push((payload.messages ?? []).map((message) => message.text).join(' '));
        break;
    }
  }

  const runs = summaries.map((text) => {
    const count = text.match(/^Test run with (\d+) tests? in \d+ suites? (passed|failed)\b/);
    return count ? { text, tests: Number(count[1]), failed: count[2] === 'failed' } : null;
  });
  // Every run that started must have a summary that reads.
  const whole = runs.length > 0 && runs.length >= started && !runs.includes(null);
  const summary = (whole ? runs.find((run) => run.failed)?.text : undefined) ?? summaries.at(-1) ?? null;
  return {
    tests: whole ? runs.reduce((sum, run) => sum + run.tests, 0) : null,
    runFailed: whole ? runs.some((run) => run.failed) : null,
    failed: [...failed].sort(),
    known: [...known].sort(),
    skipped: [...skipped].sort(),
    strayIssues,
    summary,
  };
}

const xctestCaseStarted = /^Test Case '-\[(\S+) (\S+)\]' started\.$/;
const xctestCaseEnded = /^Test Case '-\[(\S+) (\S+)\]' (passed|failed|skipped) \(/;
const xctestKnownIssue = /: Expected failure in -\[(\S+) (\S+)\]: /;
const xctestRunStarted = /^Test Suite 'All tests' started at /;
const xctestRunEnded = /^Test Suite 'All tests' (?:passed|failed) at /;
const xctestExecuted = /^\s*Executed (\d+) tests?, with /;
const swiftTestingStarted = /^\S*\s*Test run started\.$/;

/**
 * Reads XCTest's lines in the text of a `swift test` run.
 *
 * Returns `{ tests, ended, failed, known, skipped }`. A test's name is `Module.Class/method()`. `ended` is false
 * when a run started and didn't end. A text with no XCTest run reads as 0 tests, ended.
 *
 * `swift test` writes one XCTest run for each test target, and then Swift Testing's runs. So the reading stops
 * where Swift Testing's first run starts, and `tests` is the sum of the XCTest runs. A run's count comes from its
 * last end, before the next run starts. Between a test's start and its end, only that test's own lines count, so
 * what an XCTest test prints can't end the run or start Swift Testing's. A test's last end line says how it
 * ended, so a test that prints its own end line is still read. A known issue (`XCTExpectFailure`, then a
 * failure) ends with `passed`, after a line that says `Expected failure in`.
 */
export function readXCTestLog(text) {
  const failed = new Set();
  const known = new Set();
  const skipped = new Set();
  const name = (match) => `${match[1]}/${match[2]}()`;
  let finishedTests = 0; // The sum of the runs before this one.
  let runTests = 0;
  let ended = true;
  let ending = false;
  let last = null; // The test that started last.
  let running = false; // Whether `last` hasn't ended yet.
  for (const line of text.split('\n')) {
    const testEnded = line.match(xctestCaseEnded);
    if (testEnded && last !== null && name(testEnded) === last) {
      failed.delete(last);
      skipped.delete(last);
      if (testEnded[3] === 'failed') failed.add(last);
      if (testEnded[3] === 'skipped') skipped.add(last);
      running = false;
      ending = false;
      continue;
    }
    const knownIssue = line.match(xctestKnownIssue);
    if (knownIssue && last !== null && name(knownIssue) === last) {
      known.add(last);
      continue;
    }
    if (running) continue;
    const testStarted = line.match(xctestCaseStarted);
    if (testStarted) {
      last = name(testStarted);
      running = true;
    } else if (xctestRunStarted.test(line)) {
      finishedTests += runTests;
      runTests = 0;
      ended = false;
    } else if (xctestRunEnded.test(line)) {
      ending = true;
      continue;
    } else if (ending && xctestExecuted.test(line)) {
      runTests = Number(line.match(xctestExecuted)[1]);
      ended = true;
    } else if (swiftTestingStarted.test(line)) {
      break;
    }
    ending = false;
  }
  const sorted = (names) => [...names].sort();
  return { tests: finishedTests + runTests, ended, failed: sorted(failed), known: sorted(known), skipped: sorted(skipped) };
}

/** Reads the event stream at `path`. A file that is missing reads as a run with no summary. */
export function readEventStreamFile(path) {
  let text = '';
  try {
    text = readFileSync(path, 'utf8');
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  return readEventStream(text);
}

/** Whether a test's known issues are all the one that `allowedKnownIssues` names for it, by their reasons. */
function isAllowedKnownIssue(name, reasons, allowedKnownIssues) {
  const allowed = allowedKnownIssues.find((entry) => entry.test === name);
  if (allowed === undefined || reasons === undefined || reasons.length === 0) return false;
  return reasons.every((reason) => reason === allowed.reason);
}

function listed(names, limit = 10) {
  const shown = names.slice(0, limit).join(', ');
  return names.length > limit ? `${shown}, and ${names.length - limit} more` : shown;
}

/**
 * Says why a reading fails the gate, or null when it passes.
 *
 * It fails on a run with no summary, on any failure or recorded issue (a known issue is a recorded issue), on a
 * run with 0 tests, and on a skipped or cancelled test that is not in `allowedSkips`. A known issue passes only in
 * a test in `allowedKnownIssues` (`{ test, reason }`), and only when every expected failure of the test has that
 * entry's reason (`knownReasons` of the reading). A reading with no reasons, such as one from an event stream or
 * an XCTest log, has every known issue fail.
 */
export function judge(reading, allowedSkips = [], allowedKnownIssues = []) {
  if (reading.tests === null) return 'the test run has no summary';
  if (reading.failed.length > 0) return `${reading.failed.length} failed: ${listed(reading.failed)}`;
  if (reading.strayIssues > 0) return `${reading.strayIssues} recorded outside a test`;
  if (reading.runFailed) return `the test run failed: ${reading.summary}`;
  const known = reading.known.filter((name) => !isAllowedKnownIssue(name, reading.knownReasons?.[name], allowedKnownIssues));
  if (known.length > 0) {
    const shown = known.map((name) => {
      const reasons = reading.knownReasons?.[name] ?? [];
      return reasons.length === 0 ? name : `${name} (${reasons.map((reason) => `"${reason}"`).join(', ')})`;
    });
    return `${known.length} with a known issue: ${listed(shown)}`;
  }
  if (reading.tests === 0) return '0 tests ran';
  const unnamed = reading.skipped.filter((name) => !allowedSkips.includes(name));
  if (unnamed.length > 0) return `${unnamed.length} skipped, and not on the named list: ${listed(unnamed)}`;
  return null;
}

/**
 * The `check` of a step that runs Swift Testing with its event stream written to `file`. With `xctestLog`, the
 * path of the step's log, it adds the XCTest tests in that log to the reading.
 *
 * Returns the reason why the step fails, if it does, and its count of tests under `countName`.
 */
export function checkEventStream(file, { exit, countName, allowedSkips = [], xctestLog }) {
  const reading = readEventStreamFile(file);
  // With no summary, the tests didn't run to the end: the build failed, or the run died. The step's exit code
  // and its log say which. A step that says it passed with no summary fails here.
  if (reading.tests === null) return exit === 0 ? { fail: judge(reading) } : {};
  if (xctestLog !== undefined) {
    const xctest = readXCTestLog(readFileSync(xctestLog, 'utf8'));
    if (!xctest.ended) return { fail: exit === 0 ? 'the XCTest run has no summary' : undefined };
    reading.tests += xctest.tests;
    reading.failed = [...new Set([...reading.failed, ...xctest.failed])].sort();
    reading.known = [...new Set([...reading.known, ...xctest.known])].sort();
    reading.skipped = [...new Set([...reading.skipped, ...xctest.skipped])].sort();
  }
  return { fail: judge(reading, allowedSkips) ?? undefined, counts: { [countName]: reading.tests } };
}
