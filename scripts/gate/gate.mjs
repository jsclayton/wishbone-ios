// Runs the gate's steps in order, and writes its one-line result.
//
// A step is `{ name, command, limitMs }`, with these optional parts:
// - `skip`: the reason why the step doesn't run yet. A skipped step is named in the result.
// - `slot`: true when the step takes the machine-wide gate slot. The step runs with `WISHBONE_GATE_SLOT_HELD=1`
//   in its environment, so a script that takes the slot by itself (`just simulator`) knows that the gate holds it.
// - `counts`: the test counts that the step gives, such as `['package']`. Each is held against the floor.
// - `check({ exit, logPath })`: reads the step's own results after it ends, and its log. It returns
//   `{ fail, counts, names }`: `fail` is the reason why the step fails, `counts` are its test counts, and `names`
//   the names of its tests, by count, where it has them (`{ ui: [...] }`).
// - `after()`: runs when the step has ended, however it ended: it passed, it failed, it was stopped at its limit,
//   or the gate was interrupted. It stops what the step started and doesn't own, such as a simulator.
// - `crashes(report)`: says whether a crash report (see crashes.mjs) is of one of the step's test processes. When
//   the step fails, the gate keeps each such report written since the step started in the run's folder, and the
//   failure line says where the first crashed.

import { appendFileSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import path from 'node:path';

import { crashSummary, keepCrashReports } from './crashes.mjs';
import { slotHeldVariable, takeSlot } from './slot.mjs';
import { runStep } from './step.mjs';

export const countNames = ['package', 'hosted', 'ui'];

/** `72000` as `1m12s`, and `42000` as `42s`. */
export function duration(ms) {
  const seconds = Math.round(ms / 1000);
  const minutes = Math.floor(seconds / 60);
  return minutes === 0 ? `${seconds}s` : `${minutes}m${String(seconds % 60).padStart(2, '0')}s`;
}

/**
 * A step's time against its limit, such as `6m06s, 61% of its limit of 10m00s`. The share is rounded down, so a
 * step that came within a second of its limit never reads as 100%.
 */
export function usedOfLimit(ms, limitMs) {
  return `${duration(ms)}, ${Math.floor((100 * ms) / limitMs)}% of its limit of ${duration(limitMs)}`;
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
 * `part` is the name of the part of the gate that the steps are, when CI runs the gate in parts (parts.mjs). A part
 * holds no count against the floor, because its counts are only some of the gate's, and its last line is
 * `PART PASS <part> · …` or `PART FAIL <part> · …`, so it is never read as the gate's line.
 *
 * `crashReports` is `{ directory, waitMs }` for `keepCrashReports`: where the crash reports are, and how long to
 * wait for one after a failed step. Tests pass a folder of their own.
 *
 * Writes each step's output and the result to `out`. The last line is the result: `GATE PASS …` or `GATE FAIL …`.
 * Resolves with `{ ok, line, at, totalMs, counts, names }`: `at` is when it started, as an ISO time, and `names`
 * the test names that the steps' checks gave, by count.
 */
export async function runGate({
  steps,
  floor,
  part,
  root,
  runDirectory,
  slotDirectory,
  timesFile,
  floorFile = 'the floor file',
  budgetMs = Infinity,
  owner = '',
  signal,
  out = process.stdout,
  crashReports = {},
}) {
  const started = Date.now();
  const say = (line) => out.write(`${line}\n`);
  const counts = Object.fromEntries(countNames.map((name) => [name, 0]));
  const names = {};
  const times = {};
  const limits = {};
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
        if (part !== undefined) return '';
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
      const stepStarted = Date.now();
      let result;
      try {
        const env = step.slot ? { ...process.env, [slotHeldVariable]: '1' } : undefined;
        result = await runStep({ command: step.command, limitMs: step.limitMs, logPath, cwd: root, env, signal, echo: out, onStart: (pid) => slot?.watch(pid) });
      } finally {
        await step.after?.();
      }
      slot?.forget(result.pid);
      times[step.name] = result.ms;
      limits[step.name] = step.limitMs;

      if (result.interrupted) fail('interrupted');
      else if (result.timedOut) fail(`stopped at its limit of ${duration(step.limitMs)} (log: ${logName})`);
      else {
        const checked = (await step.check?.({ exit: result.exit, logPath })) ?? {};
        Object.assign(counts, checked.counts);
        Object.assign(names, checked.names);
        if (checked.fail !== undefined) fail(checked.fail);
        else if (result.exit !== 0) fail(`exit ${result.exit ?? 'on a signal'} (log: ${logName})`);
        else if (belowFloor() !== '') fail(belowFloor());
      }
      if (failure !== null && step.crashes !== undefined && !result.interrupted) {
        const kept = await keepCrashReports({ ...crashReports, since: stepStarted, into: runDirectory, matches: step.crashes });
        if (kept.length > 0) {
          const more = kept.length > 1 ? `, and ${kept.length - 1} more in ${path.relative(root, runDirectory)}` : '';
          failure += ` · ${crashSummary(kept[0].report)} (report: ${path.relative(root, kept[0].file)}${more})`;
        }
      }
      if (failure !== null) break;
      // The time against the limit, so that a step that comes near its limit shows before it fails.
      say(`── ${step.name} passed in ${usedOfLimit(result.ms, step.limitMs)}`);
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
    const record = { at: new Date(started).toISOString(), result: ok ? 'pass' : 'fail', totalMs, waitedMs, steps: times, limits, counts };
    appendFileSync(timesFile, `${JSON.stringify(record)}\n`);
  }

  if (ok && part === undefined) {
    for (const name of countNames.filter((name) => counts[name] > floor[name])) {
      say(`note: ${name}=${counts[name]} is above the floor of ${floor[name]}. Raise the floor in ${floorFile}.`);
    }
    if (totalMs > budgetMs) say(`warning: the gate took ${duration(totalMs)}, over its budget of ${duration(budgetMs)}`);
  }
  const result = ok
    ? `${countsText} · ${duration(totalMs)}${skipped.length > 0 ? ` · skipped: ${skipped.join(', ')}` : ''}`
    : failure;
  const line = part === undefined ? `GATE ${ok ? 'PASS' : 'FAIL'} ${result}` : `PART ${ok ? 'PASS' : 'FAIL'} ${part} · ${result}`;
  say(line);
  return { ok, line, at: new Date(started).toISOString(), totalMs, counts, names };
}
