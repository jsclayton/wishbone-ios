// Tests of the gate in parts (parts.mjs): the shards of the journeys, the parts' steps, and the sum of the parts.

import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import { runGate } from './gate.mjs';
import { bundleName, partNames, parts, readParts, shardNamed, shardProblem, shards, sumParts, writePart } from './parts.mjs';
import { journeyTargets, journeyTimeLines, parseArguments, resultBundles } from './simulator.mjs';
import { gateSteps } from './steps.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const floor = { package: 0, hosted: 0, ui: 0 };

/** Every test of every class that is a `JourneyTestCase` in JourneyTests/, as `Class/function`. */
function journeyTests() {
  const directory = path.join(root, 'JourneyTests');
  const tests = [];
  for (const file of readdirSync(directory).filter((name) => name.endsWith('.swift'))) {
    const source = readFileSync(path.join(directory, file), 'utf8');
    const classes = [...source.matchAll(/\bclass (\w+): JourneyTestCase\b/g)].map((match) => match[1]);
    if (classes.length === 0) continue;
    assert.equal(classes.length, 1, `${file} has one journey class, so its tests are that class's`);
    for (const match of source.matchAll(/^\s+func (test\w*)\(\)/gm)) tests.push(`${classes[0]}/${match[1]}`);
  }
  return tests.sort();
}

/** A passing part's record, as main.mjs writes it. */
const record = (part, { counts = {}, ui = [], at = '2026-11-26T10:00:00.000Z', totalMs = 60_000, ok = true } = {}) => ({
  part,
  ok,
  line: ok ? `PART PASS ${part} · …` : `PART FAIL ${part} · …`,
  at,
  totalMs,
  counts: { package: 0, hosted: 0, ui: 0, ...counts },
  ui,
});

/** One record for each part, as a green run gives them: each shard ran its own journeys. */
const greenRun = () => [
  record('build'),
  ...shards.map((shard) =>
    record(shard.name, {
      counts: { package: shard.package ? 673 : 0, hosted: shard.hosted ? 89 : 0, ui: shard.tests.length },
      ui: shard.tests.map((name) => `JourneyTests.${bundleName(name)}`),
    }),
  ),
];

test('the shards run every journey of JourneyTests, each in exactly one shard', () => {
  const sharded = shards.flatMap((shard) => shard.tests);
  const twice = sharded.filter((name, index) => sharded.indexOf(name) !== index);
  assert.deepEqual(twice, [], 'no journey is in two shards');
  assert.deepEqual([...sharded].sort(), journeyTests(), 'the shards hold every journey, and only journeys');
});

test('every shard runs at least one journey, one shard runs the hosted tests, and one the package tests', () => {
  for (const shard of shards) assert.ok(shard.tests.length > 0, `${shard.name} runs a journey`);
  assert.equal(shards.filter((shard) => shard.hosted === true).length, 1);
  assert.equal(shards.filter((shard) => shard.package === true).length, 1);
});

test("the CI workflow's journeys jobs are the shards", () => {
  const ci = readFileSync(path.join(root, '.github', 'workflows', 'ci.yml'), 'utf8');
  const listed = /^\s+shard: \[(.+)\]$/m.exec(ci);
  assert.ok(listed, 'the journeys job has a matrix of shards');
  assert.deepEqual(listed[1].split(',').map((name) => name.trim()), shards.map((shard) => shard.name));
});

test("each of the gate's steps is in a part, so the parts together run the whole gate", () => {
  const names = gateSteps({ root, runDirectory: '/run' }).map((step) => step.name);
  for (const name of names) assert.ok(partNames.some((part) => parts[part].includes(name)), `${name} is in a part`);
  for (const part of partNames) {
    for (const name of parts[part]) assert.ok(names.includes(name), `the part ${part} names the step ${name}, which the gate has`);
  }
  // Each step runs in one part, but the simulator step: each shard is a simulator step of its own. The shard that
  // runs the package tests builds them first.
  const once = names.filter((name) => name !== 'simulator');
  for (const name of once) assert.equal(partNames.filter((part) => parts[part].includes(name)).length, 1, `${name} is in one part`);
  for (const shard of shards) assert.deepEqual(parts[shard.name], shard.package ? ['package-build', 'package', 'simulator'] : ['simulator']);
});

test("a shard's simulator step runs only its shard, with the shard's own limit", () => {
  const [step] = gateSteps({ root, runDirectory: '/run', part: 'journeys-3' });
  assert.equal(step.name, 'simulator');
  assert.equal(step.command.at(-1), '--shard=journeys-3');
  const whole = gateSteps({ root, runDirectory: '/run' }).find((one) => one.name === 'simulator');
  assert.ok(!whole.command.some((arg) => arg.startsWith('--shard')), '`just gate` runs every journey');
  assert.ok(step.limitMs < whole.limitMs, "a shard's limit is below the whole step's");
  assert.throws(() => gateSteps({ root, runDirectory: '/run', part: 'journeys-9' }), /no part journeys-9/);
});

test('the simulator script takes a shard, and runs only its journeys, with the hosted tests only when the shard has them', () => {
  assert.equal(parseArguments(['out', '--no-build', '--shard=journeys-1']).shard, shardNamed('journeys-1'));
  assert.throws(() => parseArguments(['--shard=journeys-9']), /no shard is named journeys-9/);
  assert.throws(() => parseArguments(['--shard=journeys-1', '--shard=journeys-2']), /one shard, not 2/);
  assert.deepEqual(journeyTargets(undefined), ['JourneyTests']);
  assert.deepEqual(journeyTargets(shardNamed('journeys-1')), ['JourneyTests/SignInJourney/testSignIn']);
  const hosted = shards.find((shard) => shard.hosted);
  const other = shards.find((shard) => !shard.hosted);
  assert.equal(resultBundles('/run', hosted).hosted.length, 1);
  assert.deepEqual(resultBundles('/run', other).hosted, []);
  assert.equal(resultBundles('/run', other).ui.length, 2, 'a shard runs its journeys in both runs');
});

test("a shard's run must hold its own journeys, each once: no journey missing, and none of another shard's", () => {
  const shard = shardNamed('journeys-2');
  const names = shard.tests.map((name) => `JourneyTests.${bundleName(name)}`);
  assert.equal(shardProblem(names, shard), null);
  assert.equal(shardProblem([...names].reverse(), shard), null, 'the order is XCTest’s, not the shard’s');
  assert.equal(shardProblem(names.slice(1), shard), `journeys-2: it didn't run ${bundleName(shard.tests[0])}`);
  assert.equal(
    shardProblem([...names, 'JourneyTests.SignInJourney/testSignIn()'], shard),
    'journeys-2: it ran SignInJourney/testSignIn(), which another shard runs',
  );
  assert.match(shardProblem([], shard), /^journeys-2: it didn't run /, 'a shard that ran no journey fails');
});

test("the parts' counts add up to one run's, and the line is the gate's", () => {
  const { ok, lines } = sumParts(greenRun(), { floor });
  assert.equal(ok, true, lines.join('\n'));
  assert.match(lines.at(-1), new RegExp(`^GATE PASS package=673 hosted=89 ui=${journeyTests().length} · 1m00s · in ${partNames.length} parts side by side$`));
});

test("the sum's time is the parts' span, from the first start to the last end", () => {
  const records = greenRun();
  records[0].at = '2026-11-26T10:00:00.000Z';
  records[0].totalMs = 5 * 60_000;
  records.at(-1).at = '2026-11-26T10:05:00.000Z';
  records.at(-1).totalMs = 15 * 60_000 + 30_000;
  assert.match(sumParts(records, { floor }).lines.at(-1), / · 20m30s · /);
});

test('the sum fails when a part is missing, failed, is there twice, or is not one of the gate', () => {
  const run = greenRun();
  assert.equal(sumParts(run.filter((one) => one.part !== 'journeys-3'), { floor }).lines.at(-1), 'GATE FAIL no result for journeys-3');
  const failed = greenRun().map((one) => (one.part === 'journeys-4' ? { ...one, ok: false } : one));
  assert.equal(sumParts(failed, { floor }).lines.at(-1), 'GATE FAIL journeys-4 failed');
  assert.equal(sumParts([...run, record('build')], { floor }).lines.at(-1), 'GATE FAIL more than one result for build');
  assert.equal(sumParts([...run, record('journeys-9')], { floor }).lines.at(-1), "GATE FAIL a part that the gate doesn't have: journeys-9");
});

test('the sum fails when a journey ran in two shards', () => {
  const run = greenRun();
  const twice = run.find((one) => one.part === 'journeys-1').ui[0];
  run.find((one) => one.part === 'journeys-2').ui.push(twice);
  assert.equal(sumParts(run, { floor }).lines.at(-1), `GATE FAIL ${twice} ran in journeys-1 and in journeys-2`);
});

test('the sum holds the counts against the floor, and notes a count above it', () => {
  const high = { package: 673, hosted: 89, ui: journeyTests().length };
  assert.equal(sumParts(greenRun(), { floor: { ...high, ui: high.ui + 1 } }).lines.at(-1), `GATE FAIL ui=${high.ui} is below the floor of ${high.ui + 1}`);
  const { ok, lines } = sumParts(greenRun(), { floor: { ...high, package: 600 }, floorFile: 'scripts/gate/floor.json' });
  assert.equal(ok, true);
  assert.ok(lines.includes('note: package=673 is above the floor of 600. Raise the floor in scripts/gate/floor.json.'));
});

test("the parts' records are read from the folders that the artifacts unpack to", (t) => {
  const directory = mkdtempSync(path.join(tmpdir(), 'wishbone-gate-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  for (const one of greenRun()) writePart(path.join(directory, `gate-part-${one.part}`, `part-${one.part}.json`), one);
  mkdirSync(path.join(directory, 'other'));
  const read = readParts(directory);
  assert.deepEqual(read.map((one) => one.part).sort(), [...partNames].sort());
  assert.equal(sumParts(read, { floor }).ok, true);
});

test('a part holds no count against the floor, gives its own line, and the names of its journeys', async (t) => {
  const directory = mkdtempSync(path.join(tmpdir(), 'wishbone-gate-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const written = [];
  const step = {
    name: 'simulator',
    command: ['true'],
    limitMs: 60_000,
    counts: ['hosted', 'ui'],
    check: () => ({ counts: { ui: 1 }, names: { ui: ['JourneyTests.SignInJourney/testSignIn()'] } }),
  };
  const result = await runGate({
    steps: [step],
    floor: { package: 500, hosted: 50, ui: 10 },
    part: 'journeys-1',
    root: directory,
    runDirectory: path.join(directory, 'run'),
    slotDirectory: path.join(directory, 'slot'),
    out: { write: (text) => written.push(text) },
  });
  assert.equal(result.ok, true);
  assert.match(result.line, /^PART PASS journeys-1 · package=0 hosted=0 ui=1 · \d+s$/);
  assert.deepEqual(result.names, { ui: ['JourneyTests.SignInJourney/testSignIn()'] });
  assert.ok(!written.join('').includes('note:'), 'a part says nothing of the floor');
  assert.ok(!Number.isNaN(Date.parse(result.at)));
});

test("a journey's time is on a line of its own after its run, the slowest first", () => {
  assert.deepEqual(journeyTimeLines({ 'JourneyTests.A/testA()': 61_000, 'JourneyTests.B/testB()': 125_000 }), [
    '    JourneyTests.B/testB(): 2m05s',
    '    JourneyTests.A/testA(): 1m01s',
  ]);
  assert.deepEqual(journeyTimeLines(undefined), []);
});
