// The keeper: stops a step's processes when the gate that runs them is gone.
//
// The gate starts a keeper beside each step, and the gate slot's holder is a keeper too. A keeper reads lines from
// its input: `watch <pid>` and `forget <pid>`, and it starts by watching each process ID in its arguments. When its
// input ends, it stops each process that it still watches, with every process that came from it, and then exits.
// The input ends when the gate closes it, or when the gate dies, however it dies: the kernel closes the pipe.
//
// It writes `ready` when it starts, so that the slot knows when its holder has the lock.

import process from 'node:process';
import { createInterface } from 'node:readline';

import { stopFamily } from './step.mjs';

const watched = new Set(process.argv.slice(2).map(Number));
process.stdout.write('ready\n');

const lines = createInterface({ input: process.stdin });
lines.on('line', (line) => {
  const [verb, pid] = line.trim().split(/\s+/);
  if (verb === 'watch') watched.add(Number(pid));
  if (verb === 'forget') watched.delete(Number(pid));
});
lines.on('close', async () => {
  await Promise.all([...watched].filter(Number.isInteger).map((pid) => stopFamily(pid)));
  process.exit(0);
});
