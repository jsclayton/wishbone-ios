import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

import { inSlot, slotDirectory, slotHeldVariable, takeSlot } from './slot.mjs';

function scratch(t) {
  const folder = mkdtempSync(path.join(tmpdir(), 'wishbone-gate-test-'));
  t.after(() => rmSync(folder, { recursive: true, force: true }));
  return folder;
}

test('the slot folder is WISHBONE_GATE_SLOT_DIR, or a folder under the cache folder', () => {
  assert.equal(slotDirectory({ WISHBONE_GATE_SLOT_DIR: '/somewhere/slot' }), '/somewhere/slot');
  assert.match(slotDirectory({}), /\/Library\/Caches\/wishbone-gate$/);
  assert.match(slotDirectory({ WISHBONE_GATE_SLOT_DIR: '' }), /\/Library\/Caches\/wishbone-gate$/);
});

test('the second taker waits until the first lets go, and learns who holds the slot', async (t) => {
  const folder = scratch(t);
  const events = [];
  const first = await takeSlot(folder, { owner: 'the first gate' });
  let holder = null;
  const waiting = takeSlot(folder, { owner: 'the second gate', waitNoticeMs: 50, onWait: (line) => (holder = line) }).then((slot) => {
    events.push('second holds');
    return slot;
  });
  await sleep(300);
  assert.equal(holder, 'the first gate');
  events.push('first lets go');
  await first.release();
  const second = await waiting;
  assert.deepEqual(events, ['first lets go', 'second holds']);
  assert.ok(second.waitedMs >= 250, `the second taker waited (${second.waitedMs} ms)`);
  await second.release();
});

test('the slot is free again when its holder is killed', async (t) => {
  const folder = scratch(t);
  const slotModule = fileURLToPath(new URL('./slot.mjs', import.meta.url));
  const script = `import(${JSON.stringify(slotModule)}).then(({ takeSlot }) => takeSlot(${JSON.stringify(folder)})).then(() => { console.log('held'); setInterval(() => {}, 1000); });`;
  const other = spawn(process.execPath, ['-e', script], { stdio: ['ignore', 'pipe', 'inherit'] });
  t.after(() => other.kill('SIGKILL'));
  await new Promise((resolve) => other.stdout.once('data', resolve));

  let waited = false;
  const waiting = takeSlot(folder, { waitNoticeMs: 50, onWait: () => (waited = true) });
  await sleep(300);
  assert.equal(waited, true, 'the other process holds the slot');
  other.kill('SIGKILL');
  const slot = await waiting;
  await slot.release();
});

test('an interrupt ends the wait', async (t) => {
  const folder = scratch(t);
  const first = await takeSlot(folder);
  const interrupt = new AbortController();
  const waiting = takeSlot(folder, { signal: interrupt.signal });
  await sleep(100);
  interrupt.abort();
  await assert.rejects(waiting, /interrupted/);
  await first.release();
});

function isAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

test('a gate that is killed outright holds the slot until its step is stopped', async (t) => {
  const folder = scratch(t);
  const pidFile = path.join(folder, 'pids');
  const slotModule = fileURLToPath(new URL('./slot.mjs', import.meta.url));
  const stepModule = fileURLToPath(new URL('./step.mjs', import.meta.url));
  // The step ignores the request to stop, so it ends only when it is killed, a while after the gate dies.
  const script = `trap '' TERM; echo $$ > "${pidFile}"; while true; do sleep 0.1; done`;
  const gate = `
    const { takeSlot } = await import(${JSON.stringify(slotModule)});
    const { runStep } = await import(${JSON.stringify(stepModule)});
    const slot = await takeSlot(${JSON.stringify(folder)});
    await runStep({ command: ['sh', '-c', ${JSON.stringify(script)}], limitMs: 60_000, echo: null, onStart: (pid) => slot.watch(pid) });
  `;
  const other = spawn(process.execPath, ['--input-type=module', '-e', gate], { stdio: 'ignore' });
  t.after(() => other.kill('SIGKILL'));
  let pid = null;
  for (let tries = 0; pid === null; tries += 1) {
    assert.ok(tries < 250, "the gate's step didn't start");
    await sleep(20);
    try {
      pid = Number(readFileSync(pidFile, 'utf8').trim()) || null;
    } catch {
      // Not written yet.
    }
  }
  t.after(() => isAlive(pid) && process.kill(pid, 'SIGKILL'));
  other.kill('SIGKILL');
  const slot = await takeSlot(folder);
  assert.equal(isAlive(pid), false, 'the step was stopped before the slot was free');
  await slot.release();
});

test('by itself, a script waits in `inSlot` until the gate that holds the slot lets go', async (t) => {
  const folder = scratch(t);
  const events = [];
  const gate = await takeSlot(folder, { owner: 'the gate in another checkout' });
  let holder = null;
  const alone = inSlot(() => events.push('the script runs'), { env: {}, directory: folder, onWait: (line) => (holder = line) });
  await sleep(700);
  assert.equal(holder, 'the gate in another checkout');
  events.push('the gate lets go');
  await gate.release();
  await alone;
  assert.deepEqual(events, ['the gate lets go', 'the script runs']);
  // The script let go of the slot when it ended, so the next taker gets it at once.
  const next = await takeSlot(folder);
  assert.ok(next.waitedMs < 400, `the next taker didn't wait (${next.waitedMs} ms)`);
  await next.release();
});

test("under the gate, which holds the slot, a script in `inSlot` runs at once and doesn't take it again", async (t) => {
  const folder = scratch(t);
  const gate = await takeSlot(folder, { owner: 'this gate' });
  t.after(() => gate.release());
  const result = await inSlot(() => 'ran', { env: { [slotHeldVariable]: '1' }, directory: folder, onWait: () => assert.fail('it waited for the slot') });
  assert.equal(result, 'ran');
});
