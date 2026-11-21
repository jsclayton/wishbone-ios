// Reads the results of a test run, and judges them.
//
// The package tests are read from Swift Testing's event stream (`--event-stream-output-path`, version 0), not
// from the text on the terminal: a test can print anything there.

import { readFileSync } from 'node:fs';

/** A test's ID without its source location: `Module.Suite/function()`. */
function testName(id) {
  return id.replace(/\/[^/]+:\d+:\d+$/, '');
}

/**
 * Reads an event stream.
 *
 * Returns `{ tests, failed, known, skipped, strayIssues, summary }`. `tests` is the count in Swift Testing's
 * summary, or null when the stream has no summary: the run didn't finish. The lists hold test names. `skipped`
 * holds each test that was skipped, that cancelled itself, or that had a case cancelled.
 */
export function readEventStream(text) {
  const kinds = new Map();
  const failed = new Set();
  const known = new Set();
  const skipped = new Set();
  let strayIssues = 0;
  let summary = null;

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
      case 'runEnded':
        summary = (payload.messages ?? []).map((message) => message.text).join(' ');
        break;
    }
  }

  const count = summary?.match(/^Test run with (\d+) tests? in \d+ suites? (passed|failed)\b/);
  return {
    tests: count ? Number(count[1]) : null,
    runFailed: count ? count[2] === 'failed' : null,
    failed: [...failed].sort(),
    known: [...known].sort(),
    skipped: [...skipped].sort(),
    strayIssues,
    summary,
  };
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

function listed(names, limit = 10) {
  const shown = names.slice(0, limit).join(', ');
  return names.length > limit ? `${shown}, and ${names.length - limit} more` : shown;
}

/**
 * Says why a reading fails the gate, or null when it passes.
 *
 * It fails on a run with no summary, on any failure or recorded issue (a known issue is a recorded issue), on a
 * run with 0 tests, and on a skipped or cancelled test that is not in `allowedSkips`.
 */
export function judge(reading, allowedSkips = []) {
  if (reading.tests === null) return 'the test run has no summary';
  if (reading.failed.length > 0) return `${reading.failed.length} failed: ${listed(reading.failed)}`;
  if (reading.strayIssues > 0) return `${reading.strayIssues} recorded outside a test`;
  if (reading.runFailed) return `the test run failed: ${reading.summary}`;
  if (reading.known.length > 0) return `${reading.known.length} with a known issue: ${listed(reading.known)}`;
  if (reading.tests === 0) return '0 tests ran';
  const unnamed = reading.skipped.filter((name) => !allowedSkips.includes(name));
  if (unnamed.length > 0) return `${unnamed.length} skipped, and not on the named list: ${listed(unnamed)}`;
  return null;
}

/**
 * The `check` of a step that runs Swift Testing with its event stream written to `file`.
 *
 * Returns the reason why the step fails, if it does, and its count of tests under `countName`.
 */
export function checkEventStream(file, { exit, countName, allowedSkips = [] }) {
  const reading = readEventStreamFile(file);
  // With no summary, the tests didn't run to the end: the build failed, or the run died. The step's exit code
  // and its log say which. A step that says it passed with no summary fails here.
  if (reading.tests === null) return exit === 0 ? { fail: judge(reading) } : {};
  return { fail: judge(reading, allowedSkips) ?? undefined, counts: { [countName]: reading.tests } };
}
