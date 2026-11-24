// Tests of scripts/xcode-cloud-build.sh: the Gate check before a build. Each test runs the script with fakes of `gh`,
// `asc` and `sleep` first on the PATH, so no test starts a CI run or an Xcode Cloud build, or calls App Store Connect.

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('./xcode-cloud-build.sh', import.meta.url));
const sha = 'abc123abc123abc123abc123abc123abc123abc1';
const runUrl = (id) => `https://github.com/jsclayton/wishbone-ios/actions/runs/${id}`;

// gh: answers from files in the fakes' folder. `runs.json` is the list of runs. Each `gh run view` takes the next
// line of `views.jsonl`, and the last line repeats. `gh workflow run` prints the URL of run 900.
const fakeGh = String.raw`#!/bin/bash
dir="$(dirname "$0")"
echo "gh $*" >> "$dir/calls.log"
case "$1 $2" in
  "api repos/"*) echo "${sha}" ;;
  "run list") cat "$dir/runs.json" ;;
  "workflow run") echo "${runUrl(900)}" ;;
  "run view")
    n="$(cat "$dir/view-count" 2>/dev/null || echo 0)"
    echo $((n + 1)) > "$dir/view-count"
    total="$(wc -l < "$dir/views.jsonl")"
    line=$((n + 1)); [ "$line" -gt "$total" ] && line="$total"
    sed -n "$line"p "$dir/views.jsonl"
    ;;
  *) echo "fake gh: unexpected $*" >&2; exit 1 ;;
esac
`;

// asc: a build run that succeeds, a build, and the calls that set its notes and group.
const fakeAsc = String.raw`#!/bin/bash
dir="$(dirname "$0")"
echo "asc $*" >> "$dir/calls.log"
case "$1 $2 $3" in
  "xcode-cloud run "*) echo '{"data":{"id":"run-1"}}' ;;
  "xcode-cloud build-runs view") echo '{"data":{"attributes":{"executionProgress":"COMPLETE","completionStatus":"SUCCEEDED","number":7}}}' ;;
  "xcode-cloud build-runs builds") echo '{"data":[{"id":"build-1","attributes":{"version":"7"}}]}' ;;
  "builds test-notes list") echo '{"data":[]}' ;;
  *) echo '{}' ;;
esac
`;

function run(t, args, { runs = [], views = ['{"status":"completed","conclusion":"success"}'] } = {}) {
  const dir = mkdtempSync(path.join(tmpdir(), 'wishbone-cloud-build-test-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  for (const [name, body] of [
    ['gh', fakeGh],
    ['asc', fakeAsc],
    ['sleep', '#!/bin/bash\n'],
  ]) {
    writeFileSync(path.join(dir, name), body);
    chmodSync(path.join(dir, name), 0o755);
  }
  writeFileSync(path.join(dir, 'runs.json'), JSON.stringify(runs));
  writeFileSync(path.join(dir, 'views.jsonl'), `${views.join('\n')}\n`);
  writeFileSync(path.join(dir, 'calls.log'), '');
  const result = spawnSync('bash', [script, ...args], {
    encoding: 'utf8',
    env: { ...process.env, PATH: `${dir}:${process.env.PATH}` },
  });
  const calls = readFileSync(path.join(dir, 'calls.log'), 'utf8').trim().split('\n').filter(Boolean);
  return { ...result, calls };
}

const gateRun = (id, status, conclusion = '') => ({
  databaseId: id,
  displayTitle: `Gate on ${sha}`,
  status,
  conclusion,
  url: runUrl(id),
});

const dispatched = (calls) => calls.filter((call) => call.startsWith('gh workflow run'));
const waited = (calls) => calls.filter((call) => call.startsWith('gh run view'));
const started = (calls) => calls.filter((call) => call.startsWith('asc xcode-cloud run'));

test('a Tester build starts the Gate on the branch head, from the branch, and starts the build without waiting', (t) => {
  const result = run(t, ['--branch', 'fix/1-x', 'Notes']);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(dispatched(result.calls), [`gh workflow run ci.yml --repo jsclayton/wishbone-ios --ref fix/1-x -f sha=${sha}`]);
  assert.deepEqual(waited(result.calls), []);
  assert.equal(started(result.calls).length, 1);
  assert.match(result.stdout, new RegExp(`Started the Gate on ${sha}.*${runUrl(900)}`));
  const gate = result.calls.findIndex((call) => call.startsWith('gh workflow run'));
  const build = result.calls.findIndex((call) => call.startsWith('asc xcode-cloud run'));
  assert.ok(gate < build, 'the Gate starts before the build');
});

test('a Tester build with --build-only starts the Gate and doesn\'t wait for it', (t) => {
  const result = run(t, ['--build-only']);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(dispatched(result.calls).length, 1);
  assert.deepEqual(waited(result.calls), []);
  assert.equal(started(result.calls).length, 1);
});

test('an App Store build uses a Gate run that passed on the same commit, and starts no other', (t) => {
  const result = run(t, ['--app-store', 'Notes'], { runs: [gateRun(5, 'completed', 'success')] });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(dispatched(result.calls), []);
  assert.deepEqual(waited(result.calls), []);
  assert.equal(started(result.calls).length, 1);
  assert.match(result.stdout, new RegExp(`The Gate passed on ${sha}: ${runUrl(5)}`));
});

test('an App Store build with no Gate run starts one, waits for it to pass, then starts the build', (t) => {
  const result = run(t, ['--app-store', 'Notes'], {
    views: ['{"status":"queued","conclusion":""}', '{"status":"in_progress","conclusion":""}', '{"status":"completed","conclusion":"success"}'],
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(dispatched(result.calls).length, 1);
  assert.deepEqual(waited(result.calls), Array(3).fill('gh run view 900 --repo jsclayton/wishbone-ios --json status,conclusion'));
  assert.equal(started(result.calls).length, 1);
});

test('an App Store build starts no build when the Gate fails', (t) => {
  const result = run(t, ['--app-store', 'Notes'], { views: ['{"status":"completed","conclusion":"failure"}'] });
  assert.equal(result.status, 1);
  assert.deepEqual(started(result.calls), []);
  assert.deepEqual(
    result.calls.filter((call) => call.startsWith('asc')),
    [],
    'nothing is sent to App Store Connect',
  );
  assert.match(result.stderr, new RegExp(`The Gate didn't pass on ${sha}, so no App Store build was started. See: ${runUrl(900)}`));
});

test('an App Store build with --build-only waits for the Gate too', (t) => {
  const result = run(t, ['--app-store', '--build-only'], { views: ['{"status":"completed","conclusion":"cancelled"}'] });
  assert.equal(result.status, 1);
  assert.deepEqual(started(result.calls), []);
});

test('an App Store build waits for a Gate run that is under way, and starts no other', (t) => {
  const result = run(t, ['--app-store', 'Notes'], { runs: [gateRun(7, 'in_progress')] });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(dispatched(result.calls), []);
  assert.deepEqual(waited(result.calls), ['gh run view 7 --repo jsclayton/wishbone-ios --json status,conclusion']);
  assert.equal(started(result.calls).length, 1);
});

test('an App Store build counts no Gate run that failed, or that ran on another commit', (t) => {
  const other = { ...gateRun(3, 'completed', 'success'), displayTitle: 'Gate on 0000000000000000000000000000000000000000' };
  const result = run(t, ['--app-store', 'Notes'], { runs: [gateRun(4, 'completed', 'failure'), other] });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(dispatched(result.calls).length, 1, 'it starts a new Gate run');
  assert.deepEqual(waited(result.calls), ['gh run view 900 --repo jsclayton/wishbone-ios --json status,conclusion']);
});
