// The gate in parts, side by side: the dispatched Gate run in CI runs the gate's steps in several jobs at once,
// each on a runner of its own, and then adds their results up to one result. See "CI" in docs/development.md.
//
// `just gate` on a Mac doesn't use this: it runs every step, one after another, as one run.
//
// - The build part lints, builds the test server, and builds the app and its test bundles. The shards run what it
//   built, so nothing is built twice.
// - Each shard runs some of the journeys, in the four settings of the audit and in the double-length
//   pseudo-language, on a simulator of its own. Each journey is in one shard, so it runs once in each setting, as
//   in one run of the gate. One shard runs the hosted tests too, and one builds the package and its tests for macOS
//   and runs them, first, while its simulator boots.
//
// Each part writes a record of its result (`writePart`). `node scripts/gate/parts.mjs <folder>` reads the records in
// the folder, checks that every part passed and that the shards ran each journey once, adds the counts up, holds
// them against the floor, and ends with the gate's own line: `GATE PASS package=… hosted=… ui=… · <time>`.

import { mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import { countNames, duration, readFloor } from './gate.mjs';

/**
 * The shards of the journeys. Each test of a class that is a `JourneyTestCase` in `JourneyTests/` is in exactly
 * one shard, as `Class/function`, and a gate test holds that. A shard's tests run in XCTest's order, by class and
 * then by function, whatever the order here.
 *
 * **A screen's first audit stays with the journey that audits it first in one sequential run.** The settings helper
 * audits each screen once in a run, the first time that a journey reaches it, and one run of `just gate` runs the
 * journeys in XCTest's order. So in one run, ClaimJourney audits Home, a person's page and Giving, and the journeys
 * after it don't audit them again. A shard whose journey reached Home without ClaimJourney audited Home in that
 * journey's state, and failed where the sequential run never looked (runs 45893856729, 45901661533 and 45907072555).
 * So each shard that holds a journey that audits a screen holds the screen's first auditor too, and a gate test holds
 * that (`firstAuditProblems`). Each shard's simulator step has a limit of its own (`shardLimitMs` in
 * scripts/gate/steps.mjs).
 *
 * Each journey's time on CI in run 45885449080, in the four settings and then in double length: SignInJourney/
 * testSignIn 11m56s and 2m51s, MoveJourney 6m52s and 3m10s, SignOutJourney 8m02s and 1m38s, PeopleJourney 7m35s,
 * AddItemJourney 6m00s and 2m01s, ClaimJourney 4m57s and 1m16s, DropGiftJourney 4m08s and 1m11s, ReorderJourney
 * 1m41s, FirstSyncFailedJourney 1m21s and 39s, testSignInToTheProfileGate 1m21s, and the hosted tests 4m27s. Each
 * run of the journeys adds about 2 to 4 minutes of Xcode's own. `hosted: true` runs the hosted tests, and
 * `package: true` builds the package and runs its tests (about 5 minutes) first.
 */
export const shards = [
  {
    // Home, a person's page and Giving: ClaimJourney audits them first, before DropGiftJourney, PeopleJourney and
    // SignInJourney/testSignIn reach them.
    //
    // PeopleJourney stays with ClaimJourney. Without it, in a shard with AddItemJourney (runs 45898045293,
    // 45901661533 and 45907072555), PeopleJourney audited a person's page itself, with four scrolls at the largest
    // text size, and took 6m05s to 8m58s. That long journey met two `simctl ui` hangs and a UI query time-out
    // (docs/development.md, "Seen on CI, not retried"). Here, it audits only the People page and a list's page, and
    // it passed in each of the 9 Gate runs after this cut, in 4m52s to 5m41s.
    name: 'journeys-1',
    tests: ['ClaimJourney/testClaim', 'DropGiftJourney/testDropGift', 'PeopleJourney/testPeople', 'SignInJourney/testSignIn'],
  },
  {
    name: 'journeys-2',
    package: true,
    tests: [
      'ScreenshotTests/testATimeOutWhileAScreenshotIsTakenIsHeldBackAndNoted',
      'ScreenshotTests/testOnlyXCTestsTimeOutIsHeldBackAndOnlyWhileAScreenshotIsTaken',
      'SignOutJourney/testSignOut',
    ],
  },
  {
    name: 'journeys-3',
    tests: [
      'FirstSyncFailedJourney/testFirstSyncFailed',
      'MoveJourney/testMove',
      'ReorderJourney/testReorder',
      'ShareExtensionJourney/testAddFromTheShareExtension',
    ],
  },
  {
    name: 'journeys-4',
    hosted: true,
    tests: ['AddItemJourney/testAddItem', 'SignInJourney/testSignInToTheProfileGate'],
  },
];

/**
 * The screens that each journey audits, read from the Swift files of `JourneyTests/`: `{ 'Class/function':
 * ['Home', ...] }`. A screen is the name that a journey gives `Audit.run(on:showing:in:)`, as a string, or as the
 * loop's variable of a `for <name> in ["…", …]` before it in the same function. A test's screens are its own, and
 * those of the functions of its file that it calls, and that they call.
 */
export function journeyAudits(directory) {
  const audits = {};
  for (const file of readdirSync(directory).filter((name) => name.endsWith('.swift'))) {
    const source = readFileSync(path.join(directory, file), 'utf8');
    const journey = /\bclass (\w+): JourneyTestCase\b/.exec(source)?.[1];
    if (journey === undefined) continue;
    const starts = [...source.matchAll(/\bfunc (\w+)\(/g)];
    const functions = new Map(
      starts.map((match, index) => [match[1], source.slice(match.index, starts[index + 1]?.index ?? source.length)]),
    );
    const own = (body) => {
      const screens = [...body.matchAll(/showing: "([^"]+)"/g)].map((match) => match[1]);
      for (const match of body.matchAll(/showing: (\w+)\b/g)) {
        const loops = [...body.slice(0, match.index).matchAll(new RegExp(`for ${match[1]} in \\[([^\\]]*)\\]`, 'g'))];
        screens.push(...[...(loops.at(-1)?.[1] ?? '').matchAll(/"([^"]+)"/g)].map((one) => one[1]));
      }
      return screens;
    };
    const reached = (name, seen = new Set()) => {
      if (seen.has(name)) return [];
      seen.add(name);
      const body = functions.get(name) ?? '';
      const called = [...body.matchAll(/\b(\w+)\(\)/g)].map((match) => match[1]).filter((one) => one !== name && functions.has(one));
      return [...own(body), ...called.flatMap((one) => reached(one, seen))];
    };
    for (const name of functions.keys()) {
      if (name.startsWith('test')) audits[`${journey}/${name}`] = [...new Set(reached(name))];
    }
  }
  return audits;
}

/**
 * What breaks the rule that a screen's first audit stays with the journey that audits it first in one sequential
 * run, as one line each: a shard that holds a journey that audits a screen but not the screen's first auditor.
 * `audits` is what `journeyAudits` gives. The sequential run's order is XCTest's: by class, then by function.
 */
export function firstAuditProblems(shardList, audits) {
  const order = Object.keys(audits).sort();
  const first = new Map();
  for (const test of order) for (const screen of audits[test]) if (!first.has(screen)) first.set(screen, test);
  const problems = [];
  for (const shard of shardList) {
    for (const test of shard.tests) {
      for (const screen of audits[test] ?? []) {
        const owner = first.get(screen);
        if (owner !== test && !shard.tests.includes(owner)) {
          problems.push(`${shard.name}: ${test} audits ${screen}, which ${owner} audits first in one sequential run, in another shard`);
        }
      }
    }
  }
  return problems;
}

/** The shard of that name, or an error that names the shards. */
export function shardNamed(name) {
  const shard = shards.find((one) => one.name === name);
  if (shard === undefined) throw new Error(`no shard is named ${name}. The shards are ${shards.map((one) => one.name).join(', ')}`);
  return shard;
}

/** The name that a result bundle gives a test of a shard: `SignInJourney/testSignIn` is `SignInJourney/testSignIn()`. */
export function bundleName(test) {
  return `${test}()`;
}

/**
 * What is wrong with the tests that a shard's run of the journeys held, or null. `names` are the tests' names in
 * the result bundle (`Bundle.Suite/function()`). They must be the shard's tests, each once: a test that is missing
 * didn't run in any shard, and a test that is not the shard's runs in two.
 */
export function shardProblem(names, shard) {
  const held = names.map((name) => name.slice(name.indexOf('.') + 1)).sort();
  const wanted = shard.tests.map(bundleName).sort();
  const missing = wanted.filter((name) => !held.includes(name));
  const other = held.filter((name) => !wanted.includes(name));
  if (missing.length === 0 && other.length === 0) return null;
  const parts = [];
  if (missing.length > 0) parts.push(`it didn't run ${missing.join(', ')}`);
  if (other.length > 0) parts.push(`it ran ${other.join(', ')}, which another shard runs`);
  return `${shard.name}: ${parts.join(', and ')}`;
}

/**
 * The steps of each part, by the steps' names in scripts/gate/steps.mjs. The steps of all the parts are the
 * gate's steps. The build part builds the test server, and hands it to the shards with the build. Each shard runs
 * a simulator step of its own, and the shard with `package: true` builds the package and runs its tests first.
 */
export const parts = {
  build: ['lint', 'server', 'build'],
  ...Object.fromEntries(shards.map((shard) => [shard.name, [...(shard.package ? ['package-build', 'package'] : []), 'simulator']])),
};

/** The names of the parts, in the order that the sum names them. */
export const partNames = Object.keys(parts);

/**
 * Writes a part's record: `{ part, ok, line, at, totalMs, counts, ui }`. `ui` is the names of the journeys that
 * the part ran, for the check that no journey ran in two shards.
 */
export function writePart(file, record) {
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, `${JSON.stringify(record, null, 2)}\n`);
}

/** Reads every part's record in a folder, and in its folders (an artifact can hold its own folder). */
export function readParts(directory) {
  const records = [];
  for (const entry of readdirSync(directory, { recursive: true, withFileTypes: true })) {
    if (!entry.isFile() || !/^part-.*\.json$/.test(entry.name)) continue;
    const file = path.join(entry.parentPath, entry.name);
    try {
      records.push(JSON.parse(readFileSync(file, 'utf8')));
    } catch (error) {
      throw new Error(`can't read the part's record ${file}: ${error.message}`);
    }
  }
  return records;
}

/**
 * Adds the parts' records up to one result. It fails when a part is missing, is there twice, or failed; when a
 * journey ran in two parts; and when a count is below the floor. Resolves with `{ ok, lines }`: the last line is
 * the gate's own line, `GATE PASS …` or `GATE FAIL …`.
 *
 * The time in the line is the parts' span: from the first part's start to the last part's end. It doesn't count
 * the jobs' setup, as the gate's own time doesn't, nor the wait for a runner.
 */
export function sumParts(records, { floor, floorFile = 'the floor file', names = partNames } = {}) {
  const lines = [];
  const fail = (reason) => ({ ok: false, lines: [...lines, `GATE FAIL ${reason}`] });
  for (const record of records) lines.push(`${record.part}: ${record.line}`);

  const unknown = records.filter((record) => !names.includes(record.part)).map((record) => record.part);
  if (unknown.length > 0) return fail(`a part that the gate doesn't have: ${unknown.join(', ')}`);
  const twice = names.filter((name) => records.filter((record) => record.part === name).length > 1);
  if (twice.length > 0) return fail(`more than one result for ${twice.join(', ')}`);
  const missing = names.filter((name) => !records.some((record) => record.part === name));
  if (missing.length > 0) return fail(`no result for ${missing.join(', ')}`);
  const failed = records.filter((record) => !record.ok).map((record) => record.part);
  if (failed.length > 0) return fail(`${failed.join(', ')} failed`);

  const ranBy = new Map();
  for (const record of records) {
    for (const test of record.ui ?? []) {
      if (ranBy.has(test)) return fail(`${test} ran in ${ranBy.get(test)} and in ${record.part}`);
      ranBy.set(test, record.part);
    }
  }

  const counts = Object.fromEntries(countNames.map((name) => [name, records.reduce((sum, record) => sum + (record.counts?.[name] ?? 0), 0)]));
  const low = countNames.filter((name) => counts[name] < floor[name]);
  if (low.length > 0) return fail(low.map((name) => `${name}=${counts[name]} is below the floor of ${floor[name]}`).join(', '));

  for (const name of countNames.filter((one) => counts[one] > floor[one])) {
    lines.push(`note: ${name}=${counts[name]} is above the floor of ${floor[name]}. Raise the floor in ${floorFile}.`);
  }
  const start = Math.min(...records.map((record) => Date.parse(record.at)));
  const end = Math.max(...records.map((record) => Date.parse(record.at) + record.totalMs));
  const countsText = countNames.map((name) => `${name}=${counts[name]}`).join(' ');
  lines.push(`GATE PASS ${countsText} · ${duration(end - start)} · in ${records.length} parts side by side`);
  return { ok: true, lines };
}

if (import.meta.main) {
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
  const floorFile = path.join(root, 'scripts', 'gate', 'floor.json');
  let ok = false;
  try {
    const directory = process.argv[2];
    if (directory === undefined) throw new Error('name the folder that holds the parts\' records');
    const result = sumParts(readParts(directory), { floor: readFloor(floorFile), floorFile: path.relative(root, floorFile) });
    for (const line of result.lines) console.log(line);
    ok = result.ok;
  } catch (error) {
    console.log(`GATE FAIL the sum of the parts: ${error.message}`);
  }
  process.exit(ok ? 0 : 1);
}
