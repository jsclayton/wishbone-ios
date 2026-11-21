import assert from 'node:assert/strict';
import { test } from 'node:test';

import { eventStream } from './event-stream-fixture.mjs';
import { judge, readEventStream } from './reading.mjs';

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
