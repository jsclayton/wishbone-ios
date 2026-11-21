// Builds the text of a Swift Testing event stream (version 0) for the gate's own tests. The records hold the
// fields that the gate reads, in the shape that Swift Testing 6.4 writes them.

const record = (kind, payload) => JSON.stringify({ kind, payload, version: 0 });
const event = (kind, rest) => record('event', { kind, ...rest });

/**
 * `tests` maps a test's ID, such as `Tests.Suite/adds()/Suite.swift:5:4`, to how it ends: `pass`, `fail`,
 * `known` (it passes with a known issue), `warn` (it records an issue with the severity `warning`), `skip`, `cancel`
 * (the test calls `Test.cancel`), or `cancel-case` (one case of a parameterized test calls it). `ended: false` leaves the summary out, as a run that died.
 */
export function eventStream(tests, { ended = true } = {}) {
  const lines = [];
  const suites = new Set(Object.keys(tests).map((id) => id.split('/')[0]));
  for (const suite of suites) lines.push(record('test', { kind: 'suite', id: suite, name: suite.split('.').pop() }));
  for (const id of Object.keys(tests)) lines.push(record('test', { kind: 'function', id, name: id.split('/')[1] }));
  lines.push(event('runStarted', { messages: [{ symbol: 'default', text: 'Test run started.' }] }));
  let issues = 0;
  let known = 0;
  for (const [id, outcome] of Object.entries(tests)) {
    if (outcome === 'skip') {
      lines.push(event('testSkipped', { testID: id, messages: [{ symbol: 'skip', text: 'Test skipped' }] }));
      continue;
    }
    lines.push(event('testStarted', { testID: id, messages: [] }));
    // Swift Testing writes no message for a cancelled test or case, and counts neither as an issue.
    if (outcome === 'cancel') lines.push(event('testCancelled', { testID: id, messages: [] }));
    if (outcome === 'cancel-case') {
      lines.push(event('testCaseStarted', { testID: id, messages: [] }));
      lines.push(event('testCaseCancelled', { testID: id, messages: [] }));
      lines.push(event('testCaseEnded', { testID: id, messages: [] }));
    }
    // Swift Testing 6.4 leaves a warning out of a version 0 stream. A later version can write it, with its
    // severity in the issue.
    if (outcome === 'warn') lines.push(event('issueRecorded', { testID: id, issue: { isKnown: false, _severity: 'warning' }, messages: [] }));
    if (outcome === 'fail' || outcome === 'known') {
      issues += 1;
      if (outcome === 'known') known += 1;
      lines.push(event('issueRecorded', { testID: id, issue: { isKnown: outcome === 'known' }, messages: [] }));
    }
    lines.push(event('testEnded', { testID: id, messages: [] }));
  }
  if (ended) {
    const count = Object.keys(tests).length;
    const failed = issues > known;
    const tail = issues === 0 ? '' : ` with ${issues} issue${issues === 1 ? '' : 's'}${known > 0 ? ` (including ${known} known issue${known === 1 ? '' : 's'})` : ''}`;
    const text = `Test run with ${count} test${count === 1 ? '' : 's'} in ${suites.size} suite${suites.size === 1 ? '' : 's'} ${failed ? 'failed' : 'passed'} after 0.001 seconds${tail}.`;
    lines.push(event('runEnded', { messages: [{ symbol: failed ? 'fail' : 'pass', text }] }));
  }
  return `${lines.join('\n')}\n`;
}

/**
 * Builds the lines that XCTest writes to the terminal in `swift test`, as XCTest 27 writes them. `cases` maps a
 * test's name, such as `Tests.OldTests/testAdds`, to `pass`, `fail`, `skip`, or `known` (`XCTExpectFailure`, then
 * a failure: XCTest says that the test passed). `ended: false` leaves out the end of the run, as a run that died.
 */
export function xctestLog(cases, { ended = true } = {}) {
  const at = 'at 2026-11-20 21:02:52.147.';
  const lines = [`Test Suite 'All tests' started ${at}`];
  const entries = Object.entries(cases);
  for (const [name, outcome] of entries) {
    const [module, rest] = name.split('.');
    const [suite, method] = rest.split('/');
    const id = `-[${module}.${suite} ${method}]`;
    lines.push(`Test Case '${id}' started.`);
    if (outcome === 'fail') lines.push(`/Tests/${suite}.swift:4: error: ${id} : failed - no`);
    if (outcome === 'skip') lines.push(`/Tests/${suite}.swift:4: ${id} : Test skipped - not now`);
    if (outcome === 'known') {
      lines.push(`XCTExpectFailure: matcher accepted Assertion Failure at ${suite}.swift:4: failed - no`);
      lines.push(`${suite}.swift:4: Expected failure in ${id}: failed - noReason: (not yet)`);
    }
    lines.push(`Test Case '${id}' ${{ pass: 'passed', fail: 'failed', skip: 'skipped', known: 'passed' }[outcome]} (0.001 seconds).`);
  }
  if (ended) {
    const count = (outcome) => entries.filter(([, value]) => value === outcome).length;
    const failures = count('fail');
    const skips = count('skip');
    const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;
    lines.push(`Test Suite 'All tests' ${failures > 0 ? 'failed' : 'passed'} ${at}`);
    const skipped = skips > 0 ? `${plural(skips, 'test')} skipped and ` : '';
    lines.push(`\t Executed ${plural(entries.length, 'test')}, with ${skipped}${plural(failures, 'failure')} (0 unexpected) in 0.001 (0.002) seconds`);
  }
  return `${lines.join('\n')}\n`;
}
