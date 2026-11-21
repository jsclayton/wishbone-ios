import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

import { eventStream, xctestLog } from './event-stream-fixture.mjs';
import { duration, readFloor, runGate } from './gate.mjs';
import { checkEventStream } from './reading.mjs';

/** A gate in a folder of its own, with what it wrote. */
function gateIn(t) {
  const root = mkdtempSync(path.join(tmpdir(), 'wishbone-gate-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const written = [];
  const options = {
    root,
    runDirectory: path.join(root, 'run'),
    slotDirectory: path.join(root, 'slot'),
    timesFile: path.join(root, 'times.jsonl'),
    floor: { package: 0, hosted: 0, ui: 0 },
    out: { write: (text) => written.push(text) },
  };
  return { root, options, lines: () => written.join('').split('\n').filter(Boolean) };
}

// A step that is not about its limit gets one far past its work, so a busy machine doesn't stop it.
const noLimitMs = 60 * 60_000;

const passes = (name, more = {}) => ({ name, command: ['true'], limitMs: noLimitMs, ...more });

/** A step that runs "tests": it writes the event stream that Swift Testing would, and the gate reads it. */
// With `xctest`, the step also writes the lines of an XCTest run (see `xctestLog`) to its output, as `swift test`
// does, and the gate reads them from the step's log.
function testStep(root, tests, { name = 'package', countName = 'package', allowedSkips, exit = 0, ended = true, xctest } = {}) {
  const fixture = path.join(root, `${name}-fixture.jsonl`);
  writeFileSync(fixture, eventStream(tests, { ended }));
  const terminal = path.join(root, `${name}-fixture.log`);
  writeFileSync(terminal, xctest === undefined ? '' : xctestLog(xctest));
  const events = path.join(root, 'run', `${name}-events.jsonl`);
  return {
    name,
    command: ['sh', '-c', `cp "${fixture}" "${events}"; cat "${terminal}"; exit ${exit}`],
    limitMs: noLimitMs,
    counts: [countName],
    check: ({ exit, logPath }) => checkEventStream(events, { exit, countName, allowedSkips, xctestLog: xctest === undefined ? undefined : logPath }),
  };
}

const twoPassing = { 'Tests.Suite/a()/S.swift:1:2': 'pass', 'Tests.Suite/b()/S.swift:2:2': 'pass' };

test('a gate that passes ends with its counts, its time, and the steps it skipped', async (t) => {
  const { root, options, lines } = gateIn(t);
  const steps = [
    passes('lint'),
    { name: 'server', skip: 'not yet' },
    testStep(root, twoPassing),
    passes('build', { slot: true }),
    { name: 'simulator', skip: 'not yet', slot: true, counts: ['hosted', 'ui'] },
  ];
  const result = await runGate({ ...options, steps, floor: { package: 2, hosted: 0, ui: 0 } });
  assert.equal(result.ok, true);
  assert.match(result.line, /^GATE PASS package=2 hosted=0 ui=0 · \d+s · skipped: server, simulator$/);
  assert.equal(lines().at(-1), result.line, 'the result is the last line');
  assert.ok(lines().includes('── step 2 of 5: server · skipped: not yet'));
});

test('a gate with no skipped step names none', async (t) => {
  const { root, options } = gateIn(t);
  const result = await runGate({ ...options, steps: [passes('lint'), testStep(root, twoPassing)] });
  assert.match(result.line, /^GATE PASS package=2 hosted=0 ui=0 · \d+s$/);
});

test('a failing test gives GATE FAIL, with the step and the name of the test', async (t) => {
  const { root, options, lines } = gateIn(t);
  const tests = { ...twoPassing, 'Tests.Suite/adds()/S.swift:3:2': 'fail' };
  const later = path.join(root, 'later-ran');
  const steps = [passes('lint'), testStep(root, tests, { exit: 1 }), { name: 'build', command: ['touch', later], limitMs: noLimitMs }];
  const result = await runGate({ ...options, steps });
  assert.equal(result.ok, false);
  assert.equal(result.line, 'GATE FAIL step 2 (package): 1 failed: Tests.Suite/adds()');
  assert.equal(lines().at(-1), result.line);
  assert.equal(existsSync(later), false, 'the first failure stops the gate');
});

test('a step that fails with nothing to read gives its exit code and its log', async (t) => {
  const { options } = gateIn(t);
  const result = await runGate({ ...options, steps: [{ name: 'lint', command: ['sh', '-c', 'echo bad; exit 7'], limitMs: noLimitMs }] });
  assert.equal(result.line, 'GATE FAIL step 1 (lint): exit 7 (log: run/1-lint.log)');
  assert.equal(readFileSync(path.join(options.runDirectory, '1-lint.log'), 'utf8'), 'bad\n');
});

test('a test run that failed to build gives its exit code', async (t) => {
  const { options } = gateIn(t);
  const events = path.join(options.runDirectory, 'none.jsonl');
  const step = { name: 'package', command: ['false'], limitMs: noLimitMs, check: ({ exit }) => checkEventStream(events, { exit, countName: 'package' }) };
  const result = await runGate({ ...options, steps: [step] });
  assert.equal(result.line, 'GATE FAIL step 1 (package): exit 1 (log: run/1-package.log)');
});

test('a test run that passes with no summary fails', async (t) => {
  const { root, options } = gateIn(t);
  const result = await runGate({ ...options, steps: [testStep(root, twoPassing, { ended: false })] });
  assert.equal(result.line, 'GATE FAIL step 1 (package): the test run has no summary');
});

test('a count below the floor fails', async (t) => {
  const { root, options } = gateIn(t);
  const result = await runGate({ ...options, steps: [testStep(root, twoPassing)], floor: { package: 3, hosted: 0, ui: 0 } });
  assert.equal(result.line, 'GATE FAIL step 1 (package): package=2 is below the floor of 3');
});

test('a skipped step fails when the floor expects its tests', async (t) => {
  const { options } = gateIn(t);
  const steps = [passes('lint'), { name: 'simulator', skip: 'not yet', counts: ['hosted', 'ui'] }];
  const result = await runGate({ ...options, steps, floor: { package: 0, hosted: 4, ui: 1 } });
  assert.equal(result.line, 'GATE FAIL step 2 (simulator): hosted=0 is below the floor of 4, ui=0 is below the floor of 1');
});

test('a count above the floor passes, with a note to raise the floor', async (t) => {
  const { root, options, lines } = gateIn(t);
  const result = await runGate({ ...options, steps: [testStep(root, twoPassing)], floor: { package: 1, hosted: 0, ui: 0 }, floorFile: 'floor.json' });
  assert.equal(result.ok, true);
  assert.ok(lines().includes('note: package=2 is above the floor of 1. Raise the floor in floor.json.'));
  assert.equal(lines().at(-1), result.line);
});

test('a bundle with 0 tests fails', async (t) => {
  const { root, options } = gateIn(t);
  const result = await runGate({ ...options, steps: [testStep(root, {}, { name: 'simulator', countName: 'hosted' })] });
  assert.equal(result.line, 'GATE FAIL step 1 (simulator): 0 tests ran');
});

test('a skip that is not on the named list fails, and one that is on it passes', async (t) => {
  const { root, options } = gateIn(t);
  const tests = { ...twoPassing, 'Tests.Suite/off()/S.swift:3:2': 'skip' };
  const unnamed = await runGate({ ...options, steps: [testStep(root, tests)] });
  assert.equal(unnamed.line, 'GATE FAIL step 1 (package): 1 skipped, and not on the named list: Tests.Suite/off()');
  const named = await runGate({ ...options, steps: [testStep(root, tests, { allowedSkips: ['Tests.Suite/off()'] })] });
  assert.match(named.line, /^GATE PASS package=3 /);
});

test('a test that cancels itself fails like a skip, and gives no reason to raise the floor', async (t) => {
  const { root, options, lines } = gateIn(t);
  const tests = { ...twoPassing, 'Tests.Suite/cancels()/S.swift:3:2': 'cancel' };
  const result = await runGate({ ...options, steps: [testStep(root, tests)], floor: { package: 2, hosted: 0, ui: 0 } });
  assert.equal(result.line, 'GATE FAIL step 1 (package): 1 skipped, and not on the named list: Tests.Suite/cancels()');
  assert.equal(lines().some((line) => line.startsWith('note:')), false);
});

test('an XCTest test is counted with the Swift Testing tests', async (t) => {
  const { root, options } = gateIn(t);
  const step = testStep(root, twoPassing, { xctest: { 'Tests.OldTests/testA': 'pass', 'Tests.OldTests/testB': 'pass' } });
  const result = await runGate({ ...options, steps: [step], floor: { package: 4, hosted: 0, ui: 0 } });
  assert.match(result.line, /^GATE PASS package=4 /);
});

test('an XCTest test that throws XCTSkip fails unless it is on the named list', async (t) => {
  const { root, options } = gateIn(t);
  const xctest = { 'Tests.OldTests/testA': 'pass', 'Tests.OldTests/testOff': 'skip' };
  const unnamed = await runGate({ ...options, steps: [testStep(root, twoPassing, { xctest })] });
  assert.equal(unnamed.line, 'GATE FAIL step 1 (package): 1 skipped, and not on the named list: Tests.OldTests/testOff()');
  const named = await runGate({ ...options, steps: [testStep(root, twoPassing, { xctest, allowedSkips: ['Tests.OldTests/testOff()'] })] });
  assert.match(named.line, /^GATE PASS package=4 /);
});

test('a failing XCTest test fails, by name', async (t) => {
  const { root, options } = gateIn(t);
  const step = testStep(root, twoPassing, { exit: 1, xctest: { 'Tests.OldTests/testA': 'pass', 'Tests.OldTests/testB': 'fail' } });
  const result = await runGate({ ...options, steps: [step] });
  assert.equal(result.line, 'GATE FAIL step 1 (package): 1 failed: Tests.OldTests/testB()');
});

test('an XCTest test with a known issue fails, by name', async (t) => {
  const { root, options } = gateIn(t);
  const step = testStep(root, twoPassing, { xctest: { 'Tests.OldTests/testA': 'pass', 'Tests.OldTests/testKnown': 'known' } });
  const result = await runGate({ ...options, steps: [step] });
  assert.equal(result.line, 'GATE FAIL step 1 (package): 1 with a known issue: Tests.OldTests/testKnown()');
});

test('a step past its limit fails the gate, and the next step does not run', async (t) => {
  const { root, options } = gateIn(t);
  const later = path.join(root, 'later-ran');
  const steps = [
    { name: 'package', command: ['sh', '-c', 'sleep 60 & wait'], limitMs: 1_000 },
    { name: 'build', command: ['touch', later], limitMs: noLimitMs },
  ];
  const result = await runGate({ ...options, steps });
  assert.equal(result.line, 'GATE FAIL step 1 (package): stopped at its limit of 1s (log: run/1-package.log)');
  assert.equal(existsSync(later), false);
});

test('two gates at once take turns at the slot', async (t) => {
  const { root, options } = gateIn(t);
  const turns = path.join(root, 'turns');
  const go = path.join(root, 'go');
  // Each gate's slot step writes when it starts and when it ends. Each gate has its own run folder, as two
  // checkouts have, and both share the slot's folder. A slot step ends only when the other gate says that it
  // waits for the slot, so the second gate always comes while the first holds it, however busy the machine is.
  // If the slot let both in, neither would wait, and both steps would stop at their limit.
  const out = { write: (text) => text.includes('waiting for the gate slot') && writeFileSync(go, '') };
  const gate = (name) =>
    runGate({
      ...options,
      out,
      runDirectory: path.join(root, `run-${name}`),
      timesFile: path.join(root, `times-${name}.jsonl`),
      steps: [
        passes('lint'),
        {
          name: 'build',
          slot: true,
          limitMs: noLimitMs,
          command: ['sh', '-c', `echo "${name} starts" >> "${turns}"; while [ ! -e "${go}" ]; do sleep 0.05; done; echo "${name} ends" >> "${turns}"`],
        },
      ],
    });
  const results = await Promise.all([gate('one'), gate('two')]);
  assert.deepEqual(results.map((result) => result.ok), [true, true]);
  const order = readFileSync(turns, 'utf8').trim().split('\n');
  const first = order[0].split(' ')[0];
  const second = first === 'one' ? 'two' : 'one';
  assert.deepEqual(order, [`${first} starts`, `${first} ends`, `${second} starts`, `${second} ends`]);
  const waited = ['one', 'two'].map((name) => JSON.parse(readFileSync(path.join(root, `times-${name}.jsonl`), 'utf8')).waitedMs);
  // A gate says that it waits only after 500 ms of waiting.
  assert.ok(Math.max(...waited) >= 400, `one gate waited for the other (${waited} ms)`);
});

test('a step in the slot is told that the gate holds it, and a step outside it is not', async (t) => {
  const { root, options } = gateIn(t);
  const seen = path.join(root, 'seen');
  const say = (name) => ['sh', '-c', `echo "${name}=\${WISHBONE_GATE_SLOT_HELD:-unset}" >> "${seen}"`];
  const result = await runGate({ ...options, steps: [{ name: 'lint', command: say('lint'), limitMs: noLimitMs }, { name: 'build', slot: true, command: say('build'), limitMs: noLimitMs }] });
  assert.equal(result.ok, true);
  assert.deepEqual(readFileSync(seen, 'utf8').trim().split('\n'), ['lint=unset', 'build=1']);
});

test('an interrupt stops the gate at the step that runs', async (t) => {
  const { options } = gateIn(t);
  const interrupt = new AbortController();
  setTimeout(() => interrupt.abort(), 300);
  const result = await runGate({ ...options, signal: interrupt.signal, steps: [{ name: 'build', command: ['sleep', '60'], limitMs: noLimitMs }] });
  assert.equal(result.line, 'GATE FAIL step 1 (build): interrupted');
});

test('each run adds a line of step times to the log', async (t) => {
  const { root, options } = gateIn(t);
  await runGate({ ...options, steps: [passes('lint'), testStep(root, twoPassing)] });
  await runGate({ ...options, steps: [{ name: 'lint', command: ['false'], limitMs: noLimitMs }] });
  const records = readFileSync(options.timesFile, 'utf8').trim().split('\n').map((line) => JSON.parse(line));
  assert.deepEqual(records.map((record) => record.result), ['pass', 'fail']);
  assert.deepEqual(Object.keys(records[0].steps), ['lint', 'package']);
  assert.deepEqual(records[0].counts, { package: 2, hosted: 0, ui: 0 });
  assert.ok(Number.isInteger(records[0].totalMs) && !Number.isNaN(Date.parse(records[0].at)));
});

test('a gate over its budget passes, with a warning', async (t) => {
  const { options, lines } = gateIn(t);
  const result = await runGate({ ...options, budgetMs: 100, steps: [{ name: 'lint', command: ['sleep', '0.6'], limitMs: noLimitMs }] });
  assert.equal(result.ok, true);
  assert.ok(lines().some((line) => /^warning: the gate took \d+s, over its budget of 0s$/.test(line)));
  assert.equal(lines().at(-1), result.line);
});

test('the run folder holds only the last run', async (t) => {
  const { options } = gateIn(t);
  await runGate({ ...options, steps: [passes('lint'), passes('old')] });
  await runGate({ ...options, steps: [passes('lint')] });
  assert.equal(existsSync(path.join(options.runDirectory, '2-old.log')), false);
});

test('the floor file holds a whole number for each tier, and nothing else', (t) => {
  const { root } = gateIn(t);
  const file = path.join(root, 'floor.json');
  const read = (content) => {
    writeFileSync(file, content);
    return readFloor(file);
  };
  assert.deepEqual(read('{"package": 34, "hosted": 0, "ui": 0}'), { package: 34, hosted: 0, ui: 0 });
  assert.throws(() => read('{"package": 34, "hosted": 0}'), /must hold a whole number for each of package, hosted, ui/);
  assert.throws(() => read('{"package": 34, "hosted": 0, "ui": 0, "more": 1}'), /nothing else/);
  assert.throws(() => read('{"package": "34", "hosted": 0, "ui": 0}'), /whole number/);
  assert.throws(() => read('{"package": -1, "hosted": 0, "ui": 0}'), /whole number/);
  assert.throws(() => read('not json'), /can't read the floor file/);
  assert.throws(() => readFloor(path.join(root, 'missing.json')), /can't read the floor file/);
});

test('a time reads as minutes and seconds', () => {
  assert.equal(duration(42_000), '42s');
  assert.equal(duration(72_000), '1m12s');
  assert.equal(duration(242_400), '4m02s');
  assert.equal(duration(600_000), '10m00s');
});

test("a step's `after` runs however the step ends: it passes, it fails, or it is stopped at its limit", async (t) => {
  for (const [command, limitMs, expected] of [
    [['true'], noLimitMs, /^GATE PASS/],
    [['false'], noLimitMs, /^GATE FAIL step 1 \(simulator\): exit 1/],
    [['sleep', '60'], 200, /^GATE FAIL step 1 \(simulator\): stopped at its limit/],
  ]) {
    const { options } = gateIn(t);
    let ran = 0;
    const steps = [{ name: 'simulator', command, limitMs, after: () => (ran += 1) }, passes('later')];
    const result = await runGate({ ...options, steps });
    assert.match(result.line, expected);
    assert.equal(ran, 1, `after ${command.join(' ')}`);
  }
});

test("a step's `after` doesn't run for a step that is skipped", async (t) => {
  const { options } = gateIn(t);
  let ran = 0;
  const result = await runGate({ ...options, steps: [{ name: 'simulator', skip: 'not yet', after: () => (ran += 1) }] });
  assert.equal(result.ok, true);
  assert.equal(ran, 0);
});

test("the Gate job's limit in CI is above the sum of the gate's step limits, with room for the job's setup", () => {
  const main = readFileSync(new URL('./main.mjs', import.meta.url), 'utf8');
  const ci = readFileSync(new URL('../../.github/workflows/ci.yml', import.meta.url), 'utf8');
  const stepMinutes = [...main.matchAll(/^\s+limitMs: (\d+) \* minute,$/gm)].map((match) => Number(match[1]));
  assert.equal(stepMinutes.length, 5, 'each of the five steps has a limit in whole minutes');
  const gateJob = ci.slice(ci.indexOf('\n  gate:\n'), ci.indexOf('\n  ci-ok:\n'));
  const jobMinutes = Number(/^\s+timeout-minutes: (\d+)$/m.exec(gateJob)[1]);
  const sum = stepMinutes.reduce((total, minutes) => total + minutes, 0);
  assert.ok(jobMinutes >= sum + 10, `the job's ${jobMinutes} minutes are not 10 above the steps' ${sum}`);
});
