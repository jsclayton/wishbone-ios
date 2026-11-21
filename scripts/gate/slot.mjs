// The gate slot: one for the machine, so that gates from several checkouts take turns at the heavy steps.
//
// The slot is a lock on a file in the slot's folder, held by `lockf` (flock(2)). The kernel holds the lock, so it
// goes when its holder goes: a gate that dies, however it dies, leaves nothing to clean up.
//
// The holder is a keeper (keeper.mjs) that runs under `lockf`, and the gate tells it each step that it runs in the
// slot. When the gate dies, the keeper stops that step before it ends, so the slot is free only when the step's
// processes are gone.

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import { startKeeper } from './step.mjs';

const keeperFile = fileURLToPath(new URL('./keeper.mjs', import.meta.url));

/** The slot's folder: `WISHBONE_GATE_SLOT_DIR`, or a folder under the user's cache folder. */
export function slotDirectory(env = process.env) {
  const named = env.WISHBONE_GATE_SLOT_DIR;
  return named !== undefined && named !== '' ? named : path.join(homedir(), 'Library', 'Caches', 'wishbone-gate');
}

/**
 * Takes the slot, and waits for it while another gate holds it.
 *
 * `owner` is a line that says who holds the slot, for the gate that waits. `onWait` is called once, with the
 * holder's line, when the slot isn't free at once. `signal` ends the wait.
 * Resolves with `{ waitedMs, watch, forget, release }`.
 */
export function takeSlot(directory, { owner = '', onWait, signal, waitNoticeMs = 500 } = {}) {
  mkdirSync(directory, { recursive: true });
  const ownerFile = path.join(directory, 'slot.owner');
  const started = Date.now();
  // The holder says "ready" when it has the lock, then reads its input until the input ends. The input ends when
  // this process calls `release`, or exits.
  const holder = startKeeper([], { command: ['lockf', '-k', path.join(directory, 'slot.lock'), process.execPath, keeperFile], stdout: 'pipe' });
  const exited = new Promise((resolve) => holder.on('close', resolve));

  return new Promise((resolve, reject) => {
    let held = false;
    const onAbort = () => {
      if (!held) holder.kill();
    };
    if (signal?.aborted) onAbort();
    signal?.addEventListener('abort', onAbort, { once: true });
    const notice = setTimeout(() => {
      let holderLine = '';
      try {
        holderLine = readFileSync(ownerFile, 'utf8').trim();
      } catch {
        // The holder hasn't written its line yet.
      }
      onWait?.(holderLine);
    }, waitNoticeMs);

    holder.on('error', (error) => {
      clearTimeout(notice);
      reject(new Error(`the gate slot needs lockf: ${error.message}`));
    });
    holder.on('close', (code) => {
      clearTimeout(notice);
      if (held) return;
      reject(new Error(signal?.aborted ? 'interrupted' : `lockf ended with ${code} before it held the gate slot`));
    });
    holder.stdout.once('data', () => {
      held = true;
      clearTimeout(notice);
      writeFileSync(ownerFile, `${owner}\n`);
      resolve({
        waitedMs: Date.now() - started,
        // The step with this process ID runs in the slot: if this process dies, the holder stops the step first.
        watch: (pid) => holder.stdin.write(`watch ${pid}\n`),
        forget: (pid) => holder.stdin.write(`forget ${pid}\n`),
        release: async () => {
          holder.stdin.end();
          await exited;
        },
      });
    });
  });
}
