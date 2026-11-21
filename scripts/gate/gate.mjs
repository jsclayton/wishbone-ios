// Runs the gate's steps in order, and writes its one-line result.
//
// A step is `{ name, command, limitMs }`, with these optional parts:
// - `skip`: the reason why the step doesn't run yet. A skipped step is named in the result.
// - `slot`: true when the step takes the machine-wide gate slot.
// - `counts`: the test counts that the step gives, such as `['package']`. Each is held against the floor.
// - `check({ exit, logPath })`: reads the step's own results after it ends, and its log. It returns
//   `{ fail, counts }`: `fail` is the reason why the step fails, and `counts` are its test counts.
// - `after()`: runs when the step has ended, however it ended: it passed, it failed, it was stopped at its limit,
//   or the gate was interrupted. It stops what the step started and doesn't own, such as a simulator.

import { appendFileSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import path from 'node:path';

import { takeSlot } from './slot.mjs';
import { runStep } from './step.mjs';

export const countNames = ['package', 'hosted', 'ui'];

/** `72000` as `1m12s`, and `42000` as `42s`. */
export function duration(ms) {
  const seconds = Math.round(ms / 1000);
  const minutes = Math.floor(seconds / 60);
  return minutes === 0 ? `${seconds}s` : `${minutes}m${String(seconds % 60).padStart(2, '0')}s`;
}

/** Reads the floor file: the lowest count of tests that each tier may have. */
export function readFloor(file) {
  let floor;
  try {
    floor = JSON.parse(readFileSync(file, 'utf8'));
  } catch (error) {
    throw new Error(`can't read the floor file ${file}: ${error.message}`);
  }
  const keys = floor !== null && typeof floor === 'object' ? Object.keys(floor).sort() : [];
  const whole = countNames.every((name) => Number.isInteger(floor?.[name]) && floor[name] >= 0);
  if (!whole || keys.join() !== [...countNames].sort().join()) {
    throw new Error(`the floor file ${file} must hold a whole number for each of ${countNames.join(', ')}, and nothing else`);
  }
  return floor;
}

/**
 * Runs the steps. The first failure stops the gate.
 *
 * Writes each step's output and the result to `out`. The last line is the result: `GATE PASS …` or `GATE FAIL …`.
 * Resolves with `{ ok, line }`.
 */
export async function runGate({
  steps,
  floor,
  root,
  runDirectory,
  slotDirectory,
  timesFile,
  floorFile = 'the floor file',
  budgetMs = Infinity,
  owner = '',
  signal,
  out = process.stdout,
}) {
  const started = Date.now();
  const say = (line) => out.write(`${line}\n`);
  const counts = Object.fromEntries(countNames.map((name) => [name, 0]));
  const times = {};
  const skipped = [];
  let waitedMs = 0;
  let slot = null;
  let failure = null;
  let place = 'before step 1';

  // The folder holds only the last run's logs and results, so nothing stale is read as this run's.
  rmSync(runDirectory, { recursive: true, force: true });
  mkdirSync(runDirectory, { recursive: true });

  try {
    for (const [index, step] of steps.entries()) {
      const number = index + 1;
      place = `step ${number} (${step.name})`;
      const fail = (reason) => {
        failure = `${place}: ${reason}`;
      };
      const belowFloor = () => {
        const low = (step.counts ?? []).filter((name) => counts[name] < floor[name]);
        return low.map((name) => `${name}=${counts[name]} is below the floor of ${floor[name]}`).join(', ');
      };

      if (step.skip !== undefined) {
        say(`── step ${number} of ${steps.length}: ${step.name} · skipped: ${step.skip}`);
        skipped.push(step.name);
        if (belowFloor() !== '') fail(belowFloor());
        if (failure !== null) break;
        continue;
      }

      if (step.slot && slot === null) {
        slot = await takeSlot(slotDirectory, {
          owner,
          signal,
          onWait: (holder) => say(`── waiting for the gate slot${holder === '' ? '' : `, which ${holder} holds`}`),
        });
        waitedMs = slot.waitedMs;
      }
      if (signal?.aborted) {
        fail('interrupted');
        break;
      }

      say(`── step ${number} of ${steps.length}: ${step.name} (limit ${duration(step.limitMs)})`);
      const logPath = path.join(runDirectory, `${number}-${step.name}.log`);
      const logName = path.relative(root, logPath);
      let result;
      try {
        result = await runStep({ command: step.command, limitMs: step.limitMs, logPath, cwd: root, signal, echo: out, onStart: (pid) => slot?.watch(pid) });
      } finally {
        await step.after?.();
      }
      slot?.forget(result.pid);
      times[step.name] = result.ms;

      if (result.interrupted) fail('interrupted');
      else if (result.timedOut) fail(`stopped at its limit of ${duration(step.limitMs)} (log: ${logName})`);
      else {
        const checked = (await step.check?.({ exit: result.exit, logPath })) ?? {};
        Object.assign(counts, checked.counts);
        if (checked.fail !== undefined) fail(checked.fail);
        else if (result.exit !== 0) fail(`exit ${result.exit ?? 'on a signal'} (log: ${logName})`);
        else if (belowFloor() !== '') fail(belowFloor());
      }
      if (failure !== null) break;
      say(`── ${step.name} passed in ${duration(result.ms)}`);
    }
  } catch (error) {
    failure ??= `${place}: ${error.message}`;
  } finally {
    await slot?.release();
  }

  // The time that the gate itself took. The wait for another gate's turn is not part of it.
  const totalMs = Date.now() - started - waitedMs;
  const ok = failure === null;
  const countsText = countNames.map((name) => `${name}=${counts[name]}`).join(' ');

  if (timesFile !== undefined) {
    mkdirSync(path.dirname(timesFile), { recursive: true });
    const record = { at: new Date(started).toISOString(), result: ok ? 'pass' : 'fail', totalMs, waitedMs, steps: times, counts };
    appendFileSync(timesFile, `${JSON.stringify(record)}\n`);
  }

  if (ok) {
    for (const name of countNames.filter((name) => counts[name] > floor[name])) {
      say(`note: ${name}=${counts[name]} is above the floor of ${floor[name]}. Raise the floor in ${floorFile}.`);
    }
    if (totalMs > budgetMs) say(`warning: the gate took ${duration(totalMs)}, over its budget of ${duration(budgetMs)}`);
  }
  const line = ok
    ? `GATE PASS ${countsText} · ${duration(totalMs)}${skipped.length > 0 ? ` · skipped: ${skipped.join(', ')}` : ''}`
    : `GATE FAIL ${failure}`;
  say(line);
  return { ok, line };
}
