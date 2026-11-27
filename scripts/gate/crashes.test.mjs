import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

import { crashReport, stalledWaitCrash } from './crash-report-fixture.mjs';
import { crashSummary, keepCrashReports, readCrashReport } from './crashes.mjs';

/** A folder of crash reports, and a run folder to keep them in. */
function foldersIn(t) {
  const root = mkdtempSync(path.join(tmpdir(), 'wishbone-crashes-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const reports = path.join(root, 'DiagnosticReports');
  const run = path.join(root, 'run');
  mkdirSync(reports);
  mkdirSync(run);
  return { reports, run };
}

const ofTheSessionTests = (report) => report.process === 'swiftpm-testing-helper' && report.images.includes('WishboneSessionTests');

test('a crash report reads as its process, its signal, its binaries, and the crashed thread, top first', () => {
  const report = readCrashReport(crashReport());
  assert.equal(report.process, 'swiftpm-testing-helper');
  assert.equal(report.signal, 'SIGABRT');
  assert.ok(report.images.includes('WishboneSessionTests'));
  assert.equal(report.frames[0].symbol, '__pthread_kill');
  assert.equal(report.frames[0].own, false);
  assert.deepEqual(report.frames[3], { symbol: 'NetworkConditioner.Core.forward(_:)', file: 'NetworkConditioner.swift', line: 520, image: 'WishboneSessionTests', own: true });
});

test("the summary names the process, its signal, and the crashed thread's top frames in the test's own code", () => {
  assert.equal(
    crashSummary(readCrashReport(crashReport())),
    'swiftpm-testing-helper crashed (SIGABRT) at NetworkConditioner.Core.forward(_:) (NetworkConditioner.swift:520)' +
      ' ← NetworkConditioner.Core.serve(_:) (NetworkConditioner.swift:475)' +
      ' ← closure #2 in NetworkConditioner.Core.accept(_:) (NetworkConditioner.swift:438)',
  );
});

test('a crashed thread with no frame of its own shows its top frames, and a frame with no source shows its symbol', () => {
  const frames = [
    { symbol: '__pthread_kill', image: 'kernel' },
    { symbol: 'abort', image: 'c' },
    { symbol: '-[__NSURLSessionLocal taskForClassInfo:]', image: 'network' },
    { symbol: 'more', image: 'network' },
  ];
  const report = readCrashReport(crashReport({ process: 'Wishbone', signal: 'SIGSEGV', frames }));
  assert.equal(crashSummary(report, 3), 'Wishbone crashed (SIGSEGV) at __pthread_kill ← abort ← -[__NSURLSessionLocal taskForClassInfo:]');
});

test("a crash in XCTest's stall handler reads as stalled, with the main thread's frames", () => {
  const report = readCrashReport(crashReport({ process: 'JourneyTests-Runner', binary: 'JourneyTests', ...stalledWaitCrash }));
  assert.equal(report.stalled, true);
  assert.equal(report.mainFrames[0].image, 'dyld_sim');
  assert.equal(report.mainFrames.at(-1).symbol, '-[XCTestDriver _runTests]');
  assert.equal(readCrashReport(crashReport()).stalled, false);
});

test("the summary of a stalled wait names XCTest's stall handler, the wait, and where the main thread was", () => {
  const report = readCrashReport(crashReport({ process: 'JourneyTests-Runner', binary: 'JourneyTests', ...stalledWaitCrash }));
  assert.equal(
    crashSummary(report),
    "JourneyTests-Runner crashed (SIGABRT) in XCTest's stall handler (-[XCTWaiter(StallHandling) handleStalledWait:]):" +
      ' a wait on its main thread, in -[XCAXClient_iOS _loadAccessibility:], passed its time-out, and the main thread' +
      ' was still at mach_o::Header::fromDyldMapped(mach_header const*) (dyld_sim), in -[NSBundle loadAndReturnError:]' +
      ' ← -[UIApplication(UIKitApplicationAccessibility) _accessibilityBundlePrincipalClass]' +
      ' ← -[UIApplication(UIKitApplicationAccessibility) _updateApplicationAccessibility]',
  );
});

test("the summary of a stalled wait shows the test's own frames on the main thread first", () => {
  const main = [
    { symbol: 'semaphore_wait_trap', image: 'kernel' },
    { symbol: 'Journey.waitForever()', image: 'own', file: 'Journey.swift', line: 12 },
    { symbol: '+[XCTWaiter _synchronouslyWaitForTimeInterval:]', image: 'xctestCore' },
  ];
  const report = readCrashReport(crashReport({ process: 'JourneyTests-Runner', binary: 'JourneyTests', ...stalledWaitCrash, main }));
  assert.match(crashSummary(report), /a wait on its main thread passed its time-out, and the main thread was still at semaphore_wait_trap \(libsystem_kernel\.dylib\), in Journey\.waitForever\(\) \(Journey\.swift:12\)$/);
});

test('a file that is not a crash report reads as none', () => {
  assert.equal(readCrashReport('{"bug_type":"288"}\n{"what":"a hang report"}\n'), null);
  assert.equal(readCrashReport('{"bug_type":"309"}\nnot JSON'), null);
  assert.equal(readCrashReport(''), null);
});

test('it keeps the new reports of the step’s processes, and leaves the old ones and those of other processes', async (t) => {
  const { reports, run } = foldersIn(t);
  const since = Date.now() - 1000;
  const old = path.join(reports, 'swiftpm-testing-helper-2026-11-22-120000.ips');
  writeFileSync(old, crashReport());
  utimesSync(old, new Date(since - 60_000), new Date(since - 60_000));
  writeFileSync(path.join(reports, 'swiftpm-testing-helper-2026-11-23-074005.ips'), crashReport());
  writeFileSync(path.join(reports, 'swiftpm-testing-helper-2026-11-23-074006.ips'), crashReport({ binary: 'TestSupportTests' }));
  writeFileSync(path.join(reports, 'Safari-2026-11-23-074007.ips'), crashReport({ process: 'Safari', binary: 'Safari' }));
  writeFileSync(path.join(reports, 'notes.txt'), 'not a report');

  const kept = await keepCrashReports({ directory: reports, since, into: run, matches: ofTheSessionTests, waitMs: 0 });
  assert.deepEqual(kept.map(({ file }) => path.basename(file)), ['swiftpm-testing-helper-2026-11-23-074005.ips']);
  assert.equal(readFileSync(kept[0].file, 'utf8'), crashReport());
  assert.equal(kept[0].report.signal, 'SIGABRT');
  assert.equal(existsSync(path.join(run, path.basename(old))), false);
});

test('it waits for a report that macOS writes a moment after the process died', async (t) => {
  const { reports, run } = foldersIn(t);
  const since = Date.now();
  const late = setTimeout(() => writeFileSync(path.join(reports, 'swiftpm-testing-helper-late.ips'), crashReport()), 300);
  t.after(() => clearTimeout(late));
  // The wait gives up long after the report comes, so a busy machine doesn't decide the test.
  const kept = await keepCrashReports({ directory: reports, since, into: run, matches: ofTheSessionTests, waitMs: 60_000, pollMs: 50 });
  assert.deepEqual(kept.map(({ file }) => path.basename(file)), ['swiftpm-testing-helper-late.ips']);
});

test('a folder of reports that is not there has none', async (t) => {
  const { reports, run } = foldersIn(t);
  const kept = await keepCrashReports({ directory: path.join(reports, 'none'), since: 0, into: run, matches: () => true, waitMs: 0 });
  assert.deepEqual(kept, []);
});
