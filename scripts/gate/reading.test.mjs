import assert from 'node:assert/strict';
import { test } from 'node:test';

import { eventStream, xctestLog } from './event-stream-fixture.mjs';
import { judge, readEventStream, readXCTestLog } from './reading.mjs';

test('a run that passes gives its count, and nothing to fail on', () => {
  const reading = readEventStream(eventStream({ 'Tests.Suite/a()/S.swift:1:2': 'pass', 'Tests.Suite/b()/S.swift:2:2': 'pass' }));
  assert.equal(reading.tests, 2);
  assert.equal(judge(reading), null);
});

test('a failing test fails, by name', () => {
  const reading = readEventStream(eventStream({ 'Tests.Suite/a()/S.swift:1:2': 'pass', 'Tests.Suite/adds(item:)/S.swift:2:2': 'fail' }));
  assert.deepEqual(reading.failed, ['Tests.Suite/adds(item:)']);
  assert.equal(judge(reading), '1 failed: Tests.Suite/adds(item:)');
});

test('a test with two issues is named once', () => {
  const text = eventStream({ 'Tests.Suite/a()/S.swift:1:2': 'fail' });
  const issue = text.split('\n').find((line) => line.includes('issueRecorded'));
  assert.deepEqual(readEventStream(`${issue}\n${text}`).failed, ['Tests.Suite/a()']);
});

test('a known issue is a recorded issue, and fails', () => {
  const reading = readEventStream(eventStream({ 'Tests.Suite/a()/S.swift:1:2': 'known' }));
  assert.equal(judge(reading), '1 with a known issue: Tests.Suite/a()');
});

test('an issue outside a test fails', () => {
  const stray = JSON.stringify({ kind: 'event', payload: { kind: 'issueRecorded', issue: { isKnown: false } }, version: 0 });
  const reading = readEventStream(`${stray}\n${eventStream({ 'Tests.Suite/a()/S.swift:1:2': 'pass' })}`);
  assert.equal(judge(reading), '1 recorded outside a test');
});

test('a run with 0 tests fails', () => {
  const reading = readEventStream(eventStream({}));
  assert.equal(reading.tests, 0);
  assert.equal(judge(reading), '0 tests ran');
});

test('a skipped test fails unless it is on the named list', () => {
  const reading = readEventStream(eventStream({ 'Tests.Suite/a()/S.swift:1:2': 'pass', 'Tests.Suite/off()/S.swift:2:2': 'skip' }));
  assert.equal(reading.tests, 2, 'Swift Testing counts a skipped test');
  assert.equal(judge(reading), '1 skipped, and not on the named list: Tests.Suite/off()');
  assert.equal(judge(reading, ['Tests.Suite/off()']), null);
});

test('a test that cancels itself is a skip', () => {
  const reading = readEventStream(eventStream({ 'Tests.Suite/a()/S.swift:1:2': 'pass', 'Tests.Suite/cancels()/S.swift:2:2': 'cancel' }));
  assert.equal(reading.tests, 2, 'Swift Testing counts a cancelled test');
  assert.deepEqual(reading.skipped, ['Tests.Suite/cancels()']);
  assert.equal(judge(reading), '1 skipped, and not on the named list: Tests.Suite/cancels()');
  assert.equal(judge(reading, ['Tests.Suite/cancels()']), null);
});

test('a test with a cancelled case is a skip', () => {
  const reading = readEventStream(eventStream({ 'Tests.Suite/a()/S.swift:1:2': 'pass', 'Tests.Suite/cases(n:)/S.swift:2:2': 'cancel-case' }));
  assert.deepEqual(reading.skipped, ['Tests.Suite/cases(n:)']);
  assert.equal(judge(reading), '1 skipped, and not on the named list: Tests.Suite/cases(n:)');
});

test('a skipped suite is not a skipped test', () => {
  const suite = JSON.stringify({ kind: 'event', payload: { kind: 'testSkipped', testID: 'Tests.Suite' }, version: 0 });
  const text = eventStream({ 'Tests.Suite/off()/S.swift:2:2': 'skip' });
  const lines = text.split('\n');
  lines.splice(2, 0, suite);
  assert.deepEqual(readEventStream(lines.join('\n')).skipped, ['Tests.Suite/off()']);
});

test('a run that died has no summary, and fails', () => {
  const text = eventStream({ 'Tests.Suite/a()/S.swift:1:2': 'pass' }, { ended: false });
  const reading = readEventStream(`${text}{"kind":"event","payl`);
  assert.equal(reading.tests, null);
  assert.equal(judge(reading), 'the test run has no summary');
});

test('a long list of names is cut', () => {
  const tests = Object.fromEntries(Array.from({ length: 12 }, (_, index) => [`T.S/t${String(index).padStart(2, '0')}()/S.swift:1:2`, 'fail']));
  assert.match(judge(readEventStream(eventStream(tests))), /^12 failed: T\.S\/t00\(\), .*T\.S\/t09\(\), and 2 more$/);
});

test('an issue with the severity warning is not a failure', () => {
  const reading = readEventStream(eventStream({ 'Tests.Suite/a()/S.swift:1:2': 'pass', 'Tests.Suite/warns()/S.swift:2:2': 'warn' }));
  assert.deepEqual(reading.failed, []);
  assert.equal(judge(reading), null);
});

test('an XCTest run gives its count, its failures, and its skips, by name', () => {
  const reading = readXCTestLog(xctestLog({ 'Tests.OldTests/testA': 'pass', 'Tests.OldTests/testB': 'fail', 'Tests.OldTests/testOff': 'skip' }));
  assert.equal(reading.tests, 3);
  assert.deepEqual(reading.failed, ['Tests.OldTests/testB()']);
  assert.deepEqual(reading.skipped, ['Tests.OldTests/testOff()']);
});

test('a log with no XCTest run reads as 0 XCTest tests', () => {
  const reading = readXCTestLog('Building for debugging...\n􁁛  Test run with 2 tests in 1 suite passed after 0.001 seconds.\n');
  assert.equal(reading.tests, 0);
  assert.equal(reading.ended, true);
});

test('an XCTest run that died has no end', () => {
  assert.equal(readXCTestLog(xctestLog({ 'Tests.OldTests/testA': 'pass' }, { ended: false })).ended, false);
});

test('the count is the last end of the run, not a line a test printed', () => {
  const printed = "Test Suite 'All tests' passed at 2026-11-20 21:02:52.147.\n\t Executed 900 tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds\n";
  const log = xctestLog({ 'Tests.OldTests/testA': 'pass' }).replace('Test Case', `${printed}Test Case`);
  assert.equal(readXCTestLog(log).tests, 1);
});

// `swift test` runs each test target in a process of its own, and each writes its run to the one stream.
test('a stream with the runs of several test targets gives the sum of their counts', () => {
  const first = eventStream({ 'APITests.Suite/a()/S.swift:1:2': 'pass', 'APITests.Suite/b()/S.swift:2:2': 'pass' });
  const second = eventStream({ 'FitnessTests.Suite/c()/S.swift:1:2': 'pass' });
  const reading = readEventStream(first + second);
  assert.equal(reading.tests, 3);
  assert.equal(judge(reading), null);
});

test('a failure in the run of an earlier test target fails, when the last run passes', () => {
  const first = eventStream({ 'APITests.Suite/a()/S.swift:1:2': 'fail' });
  const second = eventStream({ 'FitnessTests.Suite/c()/S.swift:1:2': 'pass' });
  const reading = readEventStream(first + second);
  assert.equal(reading.tests, 2);
  assert.equal(reading.runFailed, true);
  assert.equal(judge(reading), '1 failed: APITests.Suite/a()');
});

test('a stream where the run of one test target died has no summary', () => {
  const died = eventStream({ 'APITests.Suite/a()/S.swift:1:2': 'pass' }, { ended: false });
  const whole = eventStream({ 'FitnessTests.Suite/c()/S.swift:1:2': 'pass' });
  for (const text of [died + whole, whole + died]) {
    const reading = readEventStream(text);
    assert.equal(reading.tests, null);
    assert.equal(judge(reading), 'the test run has no summary');
  }
});

test('a line that a Swift Testing test prints does not change the XCTest count', () => {
  // XCTest runs first, and Swift Testing runs after it.
  const printed = "Test Suite 'All tests' passed at 2026-11-20 21:02:52.147.\n\t Executed 900 tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds\n";
  const log = `${xctestLog({ 'Tests.OldTests/testA': 'pass' })}\u{1001C8}  Test run started.\n\u{1001C8}  Test prints() started.\n${printed}`;
  assert.equal(readXCTestLog(log).tests, 1);
});

test('a line that a Swift Testing test prints does not start an XCTest run', () => {
  const log = `${xctestLog({})}\u{1001C8}  Test run started.\nTest Suite 'All tests' started at 2026-11-20 21:02:52.147.\n`;
  assert.equal(readXCTestLog(log).ended, true);
});

test('a line that an XCTest test prints is not the start of Swift Testing', () => {
  const log = xctestLog({ 'Tests.OldTests/testA': 'pass', 'Tests.OldTests/testB': 'fail' }).replace(
    "Test Case '-[Tests.OldTests testA]' started.",
    '$&\n\u{1001C8}  Test run started.',
  );
  assert.deepEqual(readXCTestLog(log).failed, ['Tests.OldTests/testB()']);
});

test('an XCTest known issue is read by name, and fails', () => {
  const reading = readXCTestLog(xctestLog({ 'Tests.OldTests/testA': 'pass', 'Tests.OldTests/testKnown': 'known' }));
  assert.deepEqual(reading.known, ['Tests.OldTests/testKnown()']);
  assert.deepEqual(reading.failed, []);
});
