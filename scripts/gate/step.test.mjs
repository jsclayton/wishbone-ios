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

/** Waits for the step to write `count` process IDs to the file, and returns them. */
async function processIDs(file, count) {
  for (let tries = 0; tries < 100; tries += 1) {
    try {
      const pids = readFileSync(file, 'utf8').trim().split(/\s+/).map(Number);
      if (pids.length >= count) return pids;
    } catch {
      // Not written yet.
    }
    await sleep(20);
  }
  throw new Error(`the step didn't write ${count} process IDs`);
}

test('a step gives its exit code, and its output goes to the log', async (t) => {
  const folder = scratch(t);
  const logPath = path.join(folder, 'step.log');
  const result = await runStep({ command: ['sh', '-c', 'echo out; echo err >&2; exit 3'], limitMs: 10_000, logPath, echo: null });
  assert.equal(result.exit, 3);
  assert.equal(result.timedOut, false);
  assert.deepEqual(readFileSync(logPath, 'utf8').split('\n').filter(Boolean).sort(), ['err', 'out']);
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
  const running = runStep({ command: ['sh', '-c', script], limitMs: 400, echo: null, graceMs: 500 });
  const pids = await processIDs(pidFile, 5);
  assert.ok(pids.every(isAlive), 'every process runs before the limit');
  const result = await running;
  assert.equal(result.timedOut, true);
  assert.equal(result.exit, null);
  assert.ok(result.ms < 5_000, `the step stopped at its limit, not at its end (${result.ms} ms)`);
  assert.deepEqual(pids.filter(isAlive), [], 'no process is left');
});

test('a step that ignores the request to stop is killed', async (t) => {
  const folder = scratch(t);
  const pidFile = path.join(folder, 'pids');
  const script = `trap '' TERM; echo $$ > "${pidFile}"; while true; do sleep 1; done`;
  const running = runStep({ command: ['sh', '-c', script], limitMs: 300, echo: null, graceMs: 300 });
  const pids = await processIDs(pidFile, 1);
  const result = await running;
  assert.equal(result.timedOut, true);
  assert.deepEqual(pids.filter(isAlive), []);
});

test('an interrupt stops the step, with its child processes', async (t) => {
  const folder = scratch(t);
  const pidFile = path.join(folder, 'pids');
  const interrupt = new AbortController();
  const script = `echo $$ > "${pidFile}"; sleep 60 & echo $! >> "${pidFile}"; wait`;
  const running = runStep({ command: ['sh', '-c', script], limitMs: 30_000, echo: null, signal: interrupt.signal, graceMs: 500 });
  const pids = await processIDs(pidFile, 2);
  interrupt.abort();
  const result = await running;
  assert.equal(result.interrupted, true);
  assert.equal(result.timedOut, false);
  assert.deepEqual(pids.filter(isAlive), []);
});

/** Waits up to `ms` for every process in `pids` to end, and returns the ones that are still alive. */
async function survivors(pids, ms = 8_000) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline && pids.some(isAlive)) await sleep(50);
  return pids.filter(isAlive);
}

test('a step that ends on its own leaves no process behind', async (t) => {
  const folder = scratch(t);
  const pidFile = path.join(folder, 'pids');
  // The step leaves a child, and a child of a child, running when it exits.
  const script = `sleep 60 & echo $! > "${pidFile}"; sh -c 'sleep 60 & echo $! >> "${pidFile}"; wait' & exit 0`;
  const result = await runStep({ command: ['sh', '-c', script], limitMs: 10_000, echo: null, graceMs: 300 });
  assert.equal(result.exit, 0);
  assert.equal(result.timedOut, false);
  assert.deepEqual((await processIDs(pidFile, 2)).filter(isAlive), []);
});

test('a step whose gate is killed outright is stopped, with its child processes', async (t) => {
  const folder = scratch(t);
  const pidFile = path.join(folder, 'pids');
  const stepModule = fileURLToPath(new URL('./step.mjs', import.meta.url));
  const script = `echo $$ > "${pidFile}"; sleep 60 & echo $! >> "${pidFile}"; wait`;
  const gate = `import(${JSON.stringify(stepModule)}).then(({ runStep }) => runStep({ command: ['sh', '-c', ${JSON.stringify(script)}], limitMs: 60_000, echo: null }));`;
  const other = spawn(process.execPath, ['-e', gate], { stdio: 'ignore' });
  t.after(() => other.kill('SIGKILL'));
  const pids = await processIDs(pidFile, 2);
  t.after(() => pids.forEach((pid) => isAlive(pid) && process.kill(pid, 'SIGKILL')));
  assert.ok(pids.every(isAlive), 'the step runs');
  other.kill('SIGKILL');
  assert.deepEqual(await survivors(pids), [], 'no process of the step is left');
});

test('a command that does not exist is an error', async () => {
  await assert.rejects(runStep({ command: ['wishbone-no-such-command'], limitMs: 1_000, echo: null }), /ENOENT/);
});
