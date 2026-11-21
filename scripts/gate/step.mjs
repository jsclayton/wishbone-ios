// Runs one step of the gate, with a time limit.
//
// A step runs as the leader of its own process group. When it passes its limit, or the gate is interrupted,
// the step and every process that came from it are stopped: first asked (SIGTERM), then killed (SIGKILL).

import { execFileSync, spawn } from 'node:child_process';
import { createWriteStream } from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';

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
 * Runs `command` until it exits, passes `limitMs`, or `signal` aborts.
 *
 * The step's output goes to `echo` as it comes, and to the file at `logPath`.
 * Resolves with `{ exit, timedOut, interrupted, ms }`. `exit` is the exit code, or null when the step was stopped
 * or died from a signal.
 */
export function runStep({ command, limitMs, logPath, cwd, env, signal, echo = process.stdout, graceMs = 2000 }) {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const log = logPath === undefined ? null : createWriteStream(logPath);
    const [file, ...args] = command;
    // `detached` makes the step the leader of a new process group, so the group's ID is the step's process ID.
    // The step can't read the terminal from there, so it gets no input.
    const child = spawn(file, args, { cwd, env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });

    let timedOut = false;
    let interrupted = false;
    let exit = null;
    let settled = false;
    let stopping = null;
    let closeFallback = null;

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
      await stopping;
      if (log !== null) await new Promise((done) => log.end(done));
      if (error) reject(error);
      else resolve({ exit: timedOut || interrupted ? null : exit, timedOut, interrupted, ms: Date.now() - started });
    };

    for (const stream of [child.stdout, child.stderr]) {
      stream.on('data', (chunk) => {
        echo?.write(chunk);
        log?.write(chunk);
      });
    }
    child.on('error', (error) => settle(error));
    child.on('exit', (code) => {
      exit = code;
      // `close` comes when the output ends. A process that the step left behind can hold the output open, so
      // don't wait for it for long.
      closeFallback = setTimeout(() => settle(), 2000);
    });
    child.on('close', () => settle());
  });
}
