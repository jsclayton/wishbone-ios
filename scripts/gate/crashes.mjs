// Keeps the crash reports of a step's test processes, and says where each crashed.
//
// When a process crashes, macOS writes a report to `~/Library/Logs/DiagnosticReports/<process>-<time>.ips`, a
// moment after the process died. That is also where a crash in a simulator goes. The gate copies each new report
// of a failed step's test processes into the run's folder, so CI's gate-results artifact has it, and the step's
// failure line names the frames where the process crashed.
//
// An `.ips` file is a line of JSON (its header), then the report as JSON. A report names a file in the user's
// folder as `/Users/USER/*/<name>`, so a test binary is known by its name, not by its path. A report of another
// checkout's test process on the same machine, at the same time, can look the same, and is kept too.

import { copyFileSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

/** Where macOS writes its crash reports, for the processes on the Mac and for those in a simulator. */
export const diagnosticReports = path.join(homedir(), 'Library', 'Logs', 'DiagnosticReports');

/** The dispatch queue of XCTest's stall handler, which aborts a test process whose wait can't end. */
const stallQueue = 'com.apple.dt.async-test-waiter-stall';

/** XCTest's own binaries, in which a stalled wait waits. */
const xctestImages = new Set(['XCTest', 'XCTestCore', 'XCUIAutomation']);

/** The system's plumbing: a frame in one of these says little about what a thread was doing. */
const plumbing = /^(dyld|dyld_sim|libdyld\.dylib|libdispatch\.dylib|CoreFoundation|libsystem_.*)$/;

/** A thread's frames, top first, each `{ symbol, file, line, image, own }`. */
function framesOf(thread, images) {
  return (thread?.frames ?? []).map((frame) => {
    const image = images[frame.imageIndex] ?? {};
    return {
      symbol: frame.symbol ?? `${image.name ?? '???'} + ${frame.imageOffset}`,
      file: frame.sourceFile,
      line: frame.sourceLine,
      image: image.name,
      own: typeof image.path === 'string' && image.path.startsWith('/Users/'),
    };
  });
}

/**
 * Reads the text of an `.ips` crash report.
 *
 * Returns `{ process, signal, exception, images, frames, stalled, mainFrames }`, or null for a file that is not a
 * crash report. `images` holds the name of each binary in the process. `frames` are the crashed thread's, top first,
 * each `{ symbol, file, line, image, own }`, and `mainFrames` the main thread's. A frame is `own` when its binary is
 * in the user's folder: the test binary, or an app that a test runs. The other binaries are the system's and
 * Xcode's. `stalled` is true when XCTest's stall handler aborted the process: a wait passed its time-out, and the
 * thread that waited didn't come back to it.
 */
export function readCrashReport(text) {
  const end = text.indexOf('\n');
  let report;
  try {
    report = JSON.parse(text.slice(end + 1));
  } catch {
    return null;
  }
  if (report === null || typeof report !== 'object' || !Array.isArray(report.threads)) return null;
  const images = Array.isArray(report.usedImages) ? report.usedImages : [];
  const thread = report.threads[report.faultingThread] ?? report.threads.find((thread) => thread.triggered) ?? { frames: [] };
  const frames = framesOf(thread, images);
  const main = report.threads.find((thread) => thread.queue === 'com.apple.main-thread') ?? report.threads[0];
  return {
    process: report.procName ?? null,
    signal: report.exception?.signal ?? null,
    exception: report.exception?.type ?? null,
    images: images.map((image) => image.name).filter((name) => typeof name === 'string'),
    frames,
    stalled: thread.queue === stallQueue || frames.some((frame) => frame.symbol.includes('handleStalledWait')),
    mainFrames: framesOf(main, images),
  };
}

/** A frame as the failure line shows it: its symbol, and its file and line when the report has them. */
function shown(frame) {
  const file = frame.file === undefined || frame.file.startsWith('/<') ? '' : path.basename(frame.file);
  return file === '' ? frame.symbol : `${frame.symbol} (${file}${frame.line === undefined ? '' : `:${frame.line}`})`;
}

/**
 * Where the report's process crashed, in a few words: its name, its signal, and the crashed thread's top frames.
 * The top frames in the test's own code say most, so they are shown, up to `count`. A thread with no frame of its
 * own shows its top frames.
 *
 * When XCTest's stall handler aborted the process, the crashed thread says only that. So the summary names the
 * wait, and where the main thread was instead of coming back to it: its top frame, and then its first frames above
 * the wait, in the test's own code when it has some, or else outside the system's plumbing (the loader, dispatch,
 * the run loop).
 */
export function crashSummary(report, count = 3) {
  const signal = report.signal ?? report.exception ?? 'a crash';
  const name = report.process ?? 'a process';
  if (report.stalled) return stalledSummary(report, name, signal, count);
  const own = report.frames.filter((frame) => frame.own);
  const frames = (own.length > 0 ? own : report.frames).slice(0, count).map(shown);
  return `${name} crashed (${signal})${frames.length > 0 ? ` at ${frames.join(' ← ')}` : ''}`;
}

function stalledSummary(report, name, signal, count) {
  const handler = report.frames.find((frame) => frame.symbol.includes('handleStalledWait'));
  const main = report.mainFrames;
  const waitsAt = main.findIndex((frame) => xctestImages.has(frame.image));
  const above = waitsAt < 0 ? main : main.slice(0, waitsAt);
  const wait = main.find((frame) => xctestImages.has(frame.image) && !/XCTWaiter|XCTFuture/.test(frame.symbol));
  const own = above.filter((frame) => frame.own);
  const busy = (own.length > 0 ? own : above.filter((frame) => !plumbing.test(frame.image ?? ''))).slice(0, count).map(shown);
  const top = main[0];
  let where = '';
  if (top !== undefined) {
    where = `, and the main thread was still at ${shown(top)}${top.image === undefined ? '' : ` (${top.image})`}`;
    if (busy.length > 0) where += `, in ${busy.join(' ← ')}`;
  }
  return (
    `${name} crashed (${signal}) in XCTest's stall handler${handler === undefined ? '' : ` (${handler.symbol})`}: ` +
    `a wait on its main thread${wait === undefined ? '' : `, in ${wait.symbol},`} passed its time-out${where}`
  );
}

/** The reports in `directory` written at or after `since`, a time in milliseconds, that `matches` takes. */
function newReports(directory, since, matches) {
  let names;
  try {
    names = readdirSync(directory);
  } catch (error) {
    if (error.code === 'ENOENT') return [];
    throw error;
  }
  const found = [];
  for (const name of names.filter((name) => name.endsWith('.ips')).sort()) {
    const file = path.join(directory, name);
    try {
      if (statSync(file).mtimeMs < since) continue;
      const report = readCrashReport(readFileSync(file, 'utf8'));
      if (report !== null && matches(report)) found.push({ file, report });
    } catch {
      // A report that macOS is still writing, or that can't be read, is not one to keep.
    }
  }
  return found;
}

/**
 * Copies each crash report in `directory` that was written since `since` and that `matches` takes, into `into`.
 * macOS writes a report a moment after the process dies, so when none is there yet, it looks again until `waitMs`
 * has passed.
 *
 * Resolves with `[{ file, report }]`, where `file` is the copy.
 */
export async function keepCrashReports({ directory = diagnosticReports, since, into, matches, waitMs = 5000, pollMs = 250 }) {
  const deadline = Date.now() + waitMs;
  let found = newReports(directory, since, matches);
  while (found.length === 0 && Date.now() < deadline) {
    await sleep(pollMs);
    found = newReports(directory, since, matches);
  }
  return found.map(({ file, report }) => {
    const copy = path.join(into, path.basename(file));
    copyFileSync(file, copy);
    return { file: copy, report };
  });
}
