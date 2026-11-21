// Runs one step of the gate, with a time limit.
//
// A step runs as the leader of its own process group. When it passes its limit, or the gate is interrupted,
// the step and every process that came from it are stopped: first asked (SIGTERM), then killed (SIGKILL). When
// the step ends on its own, what it left behind is stopped the same way. When the gate dies, even from SIGKILL,
// the step's keeper stops them (see keeper.mjs).

import { execFileSync, spawn } from 'node:child_process';
import { createWriteStream } from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

const keeperModule = fileURLToPath(new URL('./keeper.mjs', import.meta.url));

/** The live processes that came from `root`: its process group, and every descendant of a member. */
export function family(root) {
  const listed = execFileSync('ps', ['-axo', 'pid=,ppid=,pgid='], { encoding: 'utf8' });
  const children = new Map();
  const found = new Set();
  for (const line of listed.split('\n')) {
    const [pid, parent, group] = line.trim().split(/\s+/).map(Number);
    if (!Number.isInteger(pid)) continue;
    if (pid === root || group === root) found.add(pid);
    if (!children.has(parent)) children.set(parent, []);
    children.get(parent).push(pid);
  }
  const queue = [...found];
  while (queue.length > 0) {
    for (const child of children.get(queue.pop()) ?? []) {
      if (found.has(child)) continue;
      found.add(child);
      queue.push(child);
    }
  }
  return found;
}

function isAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === 'EPERM';
  }
}

function send(pids, signal) {
  for (const pid of pids) {
    try {
      process.kill(pid, signal);
    } catch {
      // It is gone already.
    }
  }
}

/** Stops `root` and every process that came from it. */
export async function stopFamily(root, { graceMs = 2000 } = {}) {
  const asked = family(root);
  send(asked, 'SIGTERM');
  const deadline = Date.now() + graceMs;
  while (Date.now() < deadline && [...asked].some(isAlive)) await sleep(50);
  // A process that started after the first list is in the second.
  send(new Set([...asked, ...family(root)]), 'SIGKILL');
}

/**
 * Starts a keeper that watches `pids`. It is the leader of a process group of its own, so a signal from the
 * terminal to the gate's group doesn't reach it. Its input is a pipe from this process.
 */
export function startKeeper(pids = [], { command = [process.execPath, keeperModule], stdout = 'ignore' } = {}) {
  const [file, ...args] = command;
  const keeper = spawn(file, [...args, ...pids.map(String)], { detached: true, stdio: ['pipe', stdout, 'inherit'] });
  // A line to a keeper that has ended goes nowhere, and that's not an error.
  keeper.stdin.on('error', () => {});
  return keeper;
}

/**
 * Runs `command` until it exits, passes `limitMs`, or `signal` aborts. Then it stops every process that the step
 * left.
 *
 * The step's output goes to `echo` as it comes, and to the file at `logPath` a whole line at a time. `onStart`
 * is called with the step's process ID when it starts.
 * Resolves with `{ exit, timedOut, interrupted, ms, pid }`. `exit` is the exit code, or null when the step was
 * stopped or died from a signal.
 */
export function runStep({ command, limitMs, logPath, cwd, env, signal, echo = process.stdout, graceMs = 2000, onStart }) {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const log = logPath === undefined ? null : createWriteStream(logPath);
    const [file, ...args] = command;
    // `detached` makes the step the leader of a new process group, so the group's ID is the step's process ID.
    // The step can't read the terminal from there, so it gets no input.
    const child = spawn(file, args, { cwd, env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    const keeper = child.pid === undefined ? null : startKeeper([child.pid]);
    const keeperExited = keeper === null ? null : new Promise((done) => keeper.on('close', done));
    if (child.pid !== undefined) onStart?.(child.pid);

    let timedOut = false;
    let interrupted = false;
    let exit = null;
    let settled = false;
    let stopping = null;
    let closeFallback = null;
    // The log gets whole lines. Both streams go to one log, so a line that comes in two chunks would be split by
    // a chunk from the other stream between them. What is left of a line at the end goes to the log then.
    const partial = new Map();

    const stop = () => {
      stopping ??= stopFamily(child.pid, { graceMs });
      return stopping;
    };
    const limit = setTimeout(() => {
      timedOut = true;
      stop();
    }, limitMs);
    const onAbort = () => {
      interrupted = true;
      stop();
    };
    if (signal?.aborted) onAbort();
    signal?.addEventListener('abort', onAbort, { once: true });

    const settle = async (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(limit);
      clearTimeout(closeFallback);
      signal?.removeEventListener('abort', onAbort);
      // A step that ended on its own can leave processes behind. They are stopped too.
      if (child.pid !== undefined) await stop();
      if (keeper !== null) {
        keeper.stdin.end(`forget ${child.pid}\n`);
        await keeperExited;
      }
      if (log !== null) {
        for (const rest of partial.values()) if (rest.length > 0) log.write(Buffer.concat([rest, Buffer.from('\n')]));
        await new Promise((done) => log.end(done));
      }
      if (error) reject(error);
      else resolve({ exit: timedOut || interrupted ? null : exit, timedOut, interrupted, ms: Date.now() - started, pid: child.pid });
    };

    for (const stream of [child.stdout, child.stderr]) {
      partial.set(stream, Buffer.alloc(0));
      stream.on('data', (chunk) => {
        echo?.write(chunk);
        if (log === null) return;
        const text = Buffer.concat([partial.get(stream), chunk]);
        const end = text.lastIndexOf(10) + 1;
        if (end > 0) log.write(text.subarray(0, end));
        partial.set(stream, text.subarray(end));
      });
    }
    child.on('error', (error) => settle(error));
    child.on('exit', (code) => {
      exit = code;
      // `close` comes when the output ends. A process that the step left behind can hold the output open, so stop
      // those processes now, and don't wait for `close` for long.
      stop();
      closeFallback = setTimeout(() => settle(), 2000);
    });
    child.on('close', () => settle());
  });
}
