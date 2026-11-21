// Builds the text of a Swift Testing event stream (version 0) for the gate's own tests. The records hold the
// fields that the gate reads, in the shape that Swift Testing 6.4 writes them.

const record = (kind, payload) => JSON.stringify({ kind, payload, version: 0 });
const event = (kind, rest) => record('event', { kind, ...rest });

/**
 * `tests` maps a test's ID, such as `Tests.Suite/adds()/Suite.swift:5:4`, to how it ends: `pass`, `fail`,
 * `known` (it passes with a known issue), `skip`, `cancel` (the test calls `Test.cancel`), or `cancel-case` (one
 * case of a parameterized test calls it). `ended: false` leaves the summary out, as a run that died.
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
