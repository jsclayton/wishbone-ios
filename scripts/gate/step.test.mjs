import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

import { runStep } from './step.mjs';

function scratch(t) {
  const folder = mkdtempSync(path.join(tmpdir(), 'wishbone-gate-test-'));
  t.after(() => rmSync(folder, { recursive: true, force: true }));
  return folder;
}

function isAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

// The tests wait for what they need, not for a time. A busy machine can take many seconds to start a process, so a
// step that is not about its limit gets one far past any test's work, and a wait gives up only after a long time.
const noLimitMs = 60 * 60_000;
const longWaitMs = 120_000;

/** A limit that the test passes by hand: `limit.pass()` does what the limit's clock does when the time is up. */
function limitByHand() {
  let onLimit = null;
  return {
    startLimit: (ms, fire) => {
      onLimit = fire;
      return () => (onLimit = null);
    },
    pass: () => onLimit?.(),
  };
}

/**
 * The process IDs in what a step wrote to its file. The shell makes the file before it writes to it, so a read can
 * find it empty, or find its last line not yet ended. Count only ended lines that hold a process ID: an empty read
 * must not give 0, because `process.kill(0, 0)` signals this test's own process group, and so 0 is always "alive".
 */
function parseProcessIDs(text) {
  return text
    .split('\n')
    .slice(0, -1)
    .map(Number)
    .filter((pid) => Number.isInteger(pid) && pid > 0);
}

/** Waits for the step to write `count` process IDs to the file, and returns them. */
async function processIDs(file, count) {
  for (const deadline = Date.now() + longWaitMs; Date.now() < deadline; ) {
    try {
      const pids = parseProcessIDs(readFileSync(file, 'utf8'));
      if (pids.length >= count) return pids;
    } catch {
      // Not written yet.
    }
    await sleep(20);
  }
  throw new Error(`the step didn't write ${count} process IDs`);
}

test('a file that is not written yet, or not to the end of its line, holds no process ID', () => {
  assert.deepEqual(parseProcessIDs(''), []);
  assert.deepEqual(parseProcessIDs('\n'), []);
  assert.deepEqual(parseProcessIDs('123'), []);
  assert.deepEqual(parseProcessIDs('123\n45'), [123]);
  assert.deepEqual(parseProcessIDs('123\n456\n'), [123, 456]);
});

test('a step gives its exit code, and its output goes to the log', async (t) => {
  const folder = scratch(t);
  const logPath = path.join(folder, 'step.log');
  const result = await runStep({ command: ['sh', '-c', 'echo out; echo err >&2; exit 3'], limitMs: noLimitMs, logPath, echo: null });
  assert.equal(result.exit, 3);
  assert.equal(result.timedOut, false);
  assert.deepEqual(readFileSync(logPath, 'utf8').split('\n').filter(Boolean).sort(), ['err', 'out']);
});

test('a line on one stream is whole in the log, when the other stream writes in the middle of it', async (t) => {
  const folder = scratch(t);
  const logPath = path.join(folder, 'step.log');
  const script = 'printf "Test Case skipped"; sleep 0.2; echo err >&2; sleep 0.2; printf " (0.001 seconds).\\n"; printf "no end"';
  await runStep({ command: ['sh', '-c', script], limitMs: noLimitMs, logPath, echo: null });
  assert.deepEqual(readFileSync(logPath, 'utf8').split('\n').filter(Boolean).sort(), ['Test Case skipped (0.001 seconds).', 'err', 'no end']);
});

test('a step past its limit is stopped, with its child processes', async (t) => {
  const folder = scratch(t);
  const pidFile = path.join(folder, 'pids');
  // The step starts a child, a child of a child, and a child in a process group of its own (`set -m`). Then it
  // waits for them, far past its limit.
  const script = `
    echo $$ > "${pidFile}"
    sleep 60 &
    echo $! >> "${pidFile}"
    sh -c 'sleep 60 & echo $! >> "${pidFile}"; wait' &
    echo $! >> "${pidFile}"
    set -m
    sleep 60 &
    echo $! >> "${pidFile}"
    wait
  `;
  const limit = limitByHand();
  const running = runStep({ command: ['sh', '-c', script], limitMs: 400, echo: null, graceMs: 500, startLimit: limit.startLimit });
  const pids = await processIDs(pidFile, 5);
  assert.ok(pids.every(isAlive), 'every process runs before the limit');
  limit.pass();
  const result = await running;
  assert.equal(result.timedOut, true);
  assert.equal(result.exit, null);
  // Its children sleep for 60 s, so a step that ran to its end took longer than that.
  assert.ok(result.ms < 60_000, `the step stopped at its limit, not at its end (${result.ms} ms)`);
  assert.deepEqual(pids.filter(isAlive), [], 'no process is left');
});

test('a step that ignores the request to stop is killed', async (t) => {
  const folder = scratch(t);
  const pidFile = path.join(folder, 'pids');
  const script = `trap '' TERM; echo $$ > "${pidFile}"; while true; do sleep 1; done`;
  const limit = limitByHand();
  const running = runStep({ command: ['sh', '-c', script], limitMs: 300, echo: null, graceMs: 300, startLimit: limit.startLimit });
  const pids = await processIDs(pidFile, 1);
  limit.pass();
  const result = await running;
  assert.equal(result.timedOut, true);
  // `runStep` ends when the step's process has exited, and the system has taken it away, so it is gone now.
  assert.deepEqual(pids.filter(isAlive), [], 'the killed process is gone');
});

test('an interrupt stops the step, with its child processes', async (t) => {
  const folder = scratch(t);
  const pidFile = path.join(folder, 'pids');
  const interrupt = new AbortController();
  const script = `echo $$ > "${pidFile}"; sleep 60 & echo $! >> "${pidFile}"; wait`;
  const running = runStep({ command: ['sh', '-c', script], limitMs: noLimitMs, echo: null, signal: interrupt.signal, graceMs: 500 });
  const pids = await processIDs(pidFile, 2);
  interrupt.abort();
  const result = await running;
  assert.equal(result.interrupted, true);
  assert.equal(result.timedOut, false);
  assert.deepEqual(pids.filter(isAlive), []);
});

/** Waits up to `ms` for every process in `pids` to end, and returns the ones that are still alive. */
async function survivors(pids, ms = longWaitMs) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline && pids.some(isAlive)) await sleep(50);
  return pids.filter(isAlive);
}

test('a step that ends on its own leaves no process behind', async (t) => {
  const folder = scratch(t);
  const pidFile = path.join(folder, 'pids');
  // The step leaves a child, and a child of a child, running when it exits.
  const script = `sleep 60 & echo $! > "${pidFile}"; sh -c 'sleep 60 & echo $! >> "${pidFile}"; wait' & exit 0`;
  const result = await runStep({ command: ['sh', '-c', script], limitMs: noLimitMs, echo: null, graceMs: 300 });
  assert.equal(result.exit, 0);
  assert.equal(result.timedOut, false);
  assert.deepEqual((await processIDs(pidFile, 2)).filter(isAlive), []);
});

test('a step whose gate is killed outright is stopped, with its child processes', async (t) => {
  const folder = scratch(t);
  const pidFile = path.join(folder, 'pids');
  const stepModule = fileURLToPath(new URL('./step.mjs', import.meta.url));
  const script = `echo $$ > "${pidFile}"; sleep 60 & echo $! >> "${pidFile}"; wait`;
  const gate = `import(${JSON.stringify(stepModule)}).then(({ runStep }) => runStep({ command: ['sh', '-c', ${JSON.stringify(script)}], limitMs: ${noLimitMs}, echo: null }));`;
  const other = spawn(process.execPath, ['-e', gate], { stdio: 'ignore' });
  t.after(() => other.kill('SIGKILL'));
  const pids = await processIDs(pidFile, 2);
  t.after(() => pids.forEach((pid) => isAlive(pid) && process.kill(pid, 'SIGKILL')));
  assert.ok(pids.every(isAlive), 'the step runs');
  other.kill('SIGKILL');
  assert.deepEqual(await survivors(pids), [], 'no process of the step is left');
});

test('a command that does not exist is an error', async () => {
  await assert.rejects(runStep({ command: ['wishbone-no-such-command'], limitMs: noLimitMs, echo: null }), /ENOENT/);
});
