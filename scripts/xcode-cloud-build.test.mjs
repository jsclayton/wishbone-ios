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

// gh: answers from files in the fakes' folder. `runs.json` is the list of runs. Each `gh api` (the branch's head)
// takes the next line of `heads.txt`, and each `gh run view` of a wait the next line of `views.jsonl`. The last line
// repeats. The check of a run that passed (`--json conclusion,jobs`) reads `jobs-<id>.json`, or else says that the
// run passed in every part. `gh workflow run` prints the URL of run 900.
// The jobs of a Gate run in which every part passed: the Gate result job adds the parts up (ci.yml).
const jobs = (result) => [
  { name: 'Gate: build', conclusion: 'success' },
  { name: 'Gate: journeys-1', conclusion: 'success' },
  { name: 'Gate result', conclusion: result },
];
const passedJobs = JSON.stringify({ conclusion: 'success', jobs: jobs('success') });
// What a wait reads when the run ended: it passed in every part, or it ended with `conclusion`.
const ended = (conclusion, result = conclusion) => JSON.stringify({ status: 'completed', conclusion, jobs: jobs(result) });

const fakeGh = String.raw`#!/bin/bash
dir="$(dirname "$0")"
echo "gh $*" >> "$dir/calls.log"
next() {
  n="$(cat "$dir/$1.count" 2>/dev/null || echo 0)"
  echo $((n + 1)) > "$dir/$1.count"
  total="$(wc -l < "$dir/$1")"
  line=$((n + 1)); [ "$line" -gt "$total" ] && line="$total"
  sed -n "$line"p "$dir/$1"
}
case "$1 $2" in
  "api repos/"*) next heads.txt ;;
  "run list") cat "$dir/runs.json" ;;
  "workflow run") echo "${runUrl(900)}" ;;
  "run view")
    case "$*" in
      *"--json conclusion,jobs"*) cat "$dir/jobs-$3.json" 2>/dev/null || echo '${passedJobs}' ;;
      *) next views.jsonl ;;
    esac ;;
  *) echo "fake gh: unexpected $*" >&2; exit 1 ;;
esac
`;

// asc: a build run that succeeds (`build-run.json`), a build, and the calls that set its notes and group.
const fakeAsc = String.raw`#!/bin/bash
dir="$(dirname "$0")"
echo "asc $*" >> "$dir/calls.log"
case "$1 $2 $3" in
  "xcode-cloud run "*) echo '{"data":{"id":"run-1"}}' ;;
  "xcode-cloud build-runs view") cat "$dir/build-run.json" ;;
  "xcode-cloud build-runs builds") echo '{"data":[{"id":"build-1","attributes":{"version":"7"}}]}' ;;
  "builds test-notes list") echo '{"data":[]}' ;;
  *) echo '{}' ;;
esac
`;

/**
 * Run the script with the fakes. `heads` are the branch's heads on GitHub, one for each time the script asks.
 * `built` is the commit that the build run built, or null when App Store Connect doesn't say.
 */
function run(t, args, { runs = [], views = [ended('success')], jobsOf = {}, heads = [sha], built = sha } = {}) {
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
  writeFileSync(path.join(dir, 'heads.txt'), `${heads.join('\n')}\n`);
  for (const [id, body] of Object.entries(jobsOf)) writeFileSync(path.join(dir, `jobs-${id}.json`), JSON.stringify(body));
  const attributes = { executionProgress: 'COMPLETE', completionStatus: 'SUCCEEDED', number: 7 };
  if (built) attributes.sourceCommit = { commitSha: built };
  writeFileSync(path.join(dir, 'build-run.json'), JSON.stringify({ data: { attributes } }));
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
  headSha: sha,
  status,
  conclusion,
  url: runUrl(id),
});

const dispatched = (calls) => calls.filter((call) => call.startsWith('gh workflow run'));
const waited = (calls) => calls.filter((call) => call.startsWith('gh run view') && call.endsWith('--json status,conclusion,jobs'));
const checked = (calls) => calls.filter((call) => call.startsWith('gh run view') && call.endsWith('--json conclusion,jobs'));
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
    views: ['{"status":"queued","conclusion":""}', '{"status":"in_progress","conclusion":""}', ended('success')],
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(dispatched(result.calls).length, 1);
  assert.deepEqual(waited(result.calls), Array(3).fill('gh run view 900 --repo jsclayton/wishbone-ios --json status,conclusion,jobs'));
  assert.equal(started(result.calls).length, 1);
});

test('an App Store build starts no build when the Gate fails', (t) => {
  const result = run(t, ['--app-store', 'Notes'], { views: [ended('failure')] });
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
  const result = run(t, ['--app-store', '--build-only'], { views: [ended('cancelled')] });
  assert.equal(result.status, 1);
  assert.deepEqual(started(result.calls), []);
});

test('an App Store build waits for a Gate run that is under way, and starts no other', (t) => {
  const result = run(t, ['--app-store', 'Notes'], { runs: [gateRun(7, 'in_progress')] });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(dispatched(result.calls), []);
  assert.deepEqual(waited(result.calls), ['gh run view 7 --repo jsclayton/wishbone-ios --json status,conclusion,jobs']);
  assert.equal(started(result.calls).length, 1);
});

test('an App Store build counts no Gate run that failed, that checked another commit, or that ran from another commit', (t) => {
  const otherSha = '0000000000000000000000000000000000000000';
  const otherCommit = { ...gateRun(3, 'completed', 'success'), displayTitle: `Gate on ${otherSha}`, headSha: otherSha };
  // Run from another branch with `sha` set to this commit: its name matches, but its Gate job is another commit's.
  const otherWorkflow = { ...gateRun(2, 'completed', 'success'), headSha: otherSha };
  const result = run(t, ['--app-store', 'Notes'], { runs: [gateRun(4, 'completed', 'failure'), otherCommit, otherWorkflow] });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(dispatched(result.calls).length, 1, 'it starts a new Gate run');
  assert.deepEqual(waited(result.calls), ['gh run view 900 --repo jsclayton/wishbone-ios --json status,conclusion,jobs']);
});

test('an App Store build waits for the oldest Gate run that is under way, which ends first', (t) => {
  // The list is newest first.
  const result = run(t, ['--app-store', 'Notes'], { runs: [gateRun(9, 'queued'), gateRun(8, 'in_progress')] });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(dispatched(result.calls), []);
  assert.deepEqual(waited(result.calls), ['gh run view 8 --repo jsclayton/wishbone-ios --json status,conclusion,jobs']);
});

test('an App Store build prefers a Gate run that passed to one under way', (t) => {
  const result = run(t, ['--app-store', 'Notes'], { runs: [gateRun(9, 'in_progress'), gateRun(6, 'completed', 'success')] });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(waited(result.calls), []);
  assert.match(result.stdout, new RegExp(`The Gate passed on ${sha}: ${runUrl(6)}`));
});

// The Gate runs in parts, in jobs of their own, and a skipped job counts as passed for the run's conclusion. So a
// run counts only when its Gate result job, which adds the parts up and fails when one is missing, passed.
test('an App Store build counts no Gate run whose Gate result job did not pass, even when the run says it passed', (t) => {
  const result = run(t, ['--app-store', 'Notes'], {
    runs: [gateRun(6, 'completed', 'success'), gateRun(5, 'completed', 'success')],
    jobsOf: { 6: { conclusion: 'success', jobs: jobs('skipped') }, 5: { conclusion: 'success', jobs: [{ name: 'Gate', conclusion: 'success' }] } },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(checked(result.calls), [6, 5].map((id) => `gh run view ${id} --repo jsclayton/wishbone-ios --json conclusion,jobs`));
  assert.equal(dispatched(result.calls).length, 1, 'it starts a new Gate run');
  assert.deepEqual(waited(result.calls), ['gh run view 900 --repo jsclayton/wishbone-ios --json status,conclusion,jobs']);
});

test('an App Store build uses the newest Gate run that passed in every part', (t) => {
  const result = run(t, ['--app-store', 'Notes'], {
    runs: [gateRun(6, 'completed', 'success'), gateRun(5, 'completed', 'success')],
    jobsOf: { 6: { conclusion: 'success', jobs: jobs('cancelled') } },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(dispatched(result.calls), []);
  assert.match(result.stdout, new RegExp(`The Gate passed on ${sha}: ${runUrl(5)}`));
});

test('an App Store build starts no build when the Gate run ends with its Gate result job not passed', (t) => {
  const result = run(t, ['--app-store', 'Notes'], { views: [ended('success', 'skipped')] });
  assert.equal(result.status, 1);
  assert.deepEqual(started(result.calls), []);
  assert.match(result.stderr, new RegExp(`The Gate didn't pass on ${sha}, so no App Store build was started`));
});

test('an App Store build starts no build when the branch moved while the Gate ran', (t) => {
  const moved = 'def456def456def456def456def456def456def4';
  const result = run(t, ['--app-store', 'Notes'], { heads: [sha, moved] });
  assert.equal(result.status, 1);
  assert.equal(waited(result.calls).length, 1, 'it waited for the Gate first');
  assert.equal(result.calls.filter((call) => call.startsWith('gh api')).length, 2, 'it asks for the head again after the Gate');
  assert.deepEqual(
    result.calls.filter((call) => call.startsWith('asc')),
    [],
    'nothing is sent to App Store Connect',
  );
  assert.match(result.stderr, new RegExp(`'main' moved from ${sha} to ${moved} while the Gate ran; no App Store build was started. Run the command again.`));
});

test('an App Store build stops before its notes and its group when Xcode Cloud built another commit', (t) => {
  const other = 'def456def456def456def456def456def456def4';
  const result = run(t, ['--app-store', 'Notes'], { runs: [gateRun(5, 'completed', 'success')], built: other });
  assert.equal(result.status, 1);
  assert.equal(started(result.calls).length, 1);
  assert.deepEqual(
    result.calls.filter((call) => call.startsWith('asc builds')),
    [],
    'no notes, no group, and no wait for processing',
  );
  assert.match(result.stderr, new RegExp(`built ${other}, not ${sha}, which the Gate checked`));
});

test('a Tester build that built another commit goes on, and says so', (t) => {
  const other = 'def456def456def456def456def456def456def4';
  const result = run(t, ['Notes'], { built: other });
  assert.equal(result.status, 0, result.stderr);
  assert.ok(result.calls.some((call) => call.startsWith('asc builds add-groups')), 'the build goes to the group');
  assert.match(result.stdout, new RegExp(`built ${other}, not ${sha}`));
});

test('when App Store Connect doesn\'t say which commit was built, the build goes on, and says so', (t) => {
  const result = run(t, ['--app-store', 'Notes'], { runs: [gateRun(5, 'completed', 'success')], built: null });
  assert.equal(result.status, 0, result.stderr);
  assert.ok(result.calls.some((call) => call.startsWith('asc builds add-groups')), 'the build goes to the group');
  assert.match(result.stdout, /doesn't say which commit build run run-1 built/);
});
