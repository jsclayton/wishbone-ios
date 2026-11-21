import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

import { slotDirectory, takeSlot } from './slot.mjs';

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
