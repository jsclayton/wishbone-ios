import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import { builtServerProblem, wantedStamp } from './build.mjs';
import { buildPaths, goVersion, parsePin, pinFile, pinKey, stampedVersion } from './pin.mjs';

const root = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8', cwd: path.dirname(fileURLToPath(import.meta.url)) }).trim();
const pin = { repository: 'https://github.com/jsclayton/wishbone.git', tag: 'v2.2.0', commit: '7773ada196283c7cbb331ef088735f418d5b3e98' };

/** A checkout that has only a pin file. */
function checkout(t, text = JSON.stringify(pin)) {
  const folder = mkdtempSync(path.join(tmpdir(), 'wishbone-server-test-'));
  t.after(() => rmSync(folder, { recursive: true, force: true }));
  mkdirSync(path.dirname(path.join(folder, pinFile)), { recursive: true });
  writeFileSync(path.join(folder, pinFile), text);
  return folder;
}

test("the repo's pin file is a pin", () => {
  const read = parsePin(readFileSync(path.join(root, pinFile), 'utf8'));
  assert.match(read.tag, /^v\d+\.\d+\.\d+$/);
});

test('a pin gives the version that the release reports, and the name of its build folder', () => {
  assert.equal(stampedVersion(pin), '2.2.0+7773ada');
  assert.equal(pinKey(pin), 'v2.2.0-7773ada');
  assert.equal(buildPaths('/checkout', pin).binary, '/checkout/build/server/v2.2.0-7773ada/wishbone');
});

test('a pin must fetch over HTTPS, from a release tag, at a full commit', () => {
  const bad = (change) => () => parsePin(JSON.stringify({ ...pin, ...change }));
  assert.throws(bad({ repository: 'git@github.com:jsclayton/wishbone.git' }), /https:\/\//);
  assert.throws(bad({ tag: 'main' }), /release tag/);
  assert.throws(bad({ commit: '7773ada' }), /full commit SHA/);
  assert.throws(() => parsePin('not json'), /is not JSON/);
});

test("Go's version comes from the source's go.mod", () => {
  assert.equal(goVersion('module jsclayton.dev/wishbone\n\ngo 1.27.3\n\nrequire (\n)\n'), '1.27.3');
  assert.equal(goVersion('module m\n\ngo 1.27\n\ntoolchain go1.27.4\n'), '1.27.4');
  assert.throws(() => goVersion('module m\n'), /names no Go version/);
});

test('a build is reused only for the same pin, Go, and recipe', () => {
  assert.deepEqual(wantedStamp(pin, '1.27.3'), wantedStamp(pin, '1.27.3'));
  assert.notDeepEqual(wantedStamp(pin, '1.27.3'), wantedStamp(pin, '1.27.4'));
  assert.notDeepEqual(wantedStamp(pin, '1.27.3'), wantedStamp({ ...pin, tag: 'v2.2.1' }, '1.27.3'));
  assert.ok(wantedStamp(pin, '1.27.3').recipe.includes('e2e'), 'the build has the e2e tag');
});

test('a checkout with no built server has a problem that says so', (t) => {
  assert.equal(builtServerProblem(checkout(t)), 'build/server/v2.2.0-7773ada has no built server');
});

test('a server that reports another version is not the built server', (t) => {
  const folder = checkout(t);
  const paths = buildPaths(folder, pin);
  mkdirSync(paths.source, { recursive: true });
  writeFileSync(path.join(paths.source, 'go.mod'), 'module m\n\ngo 1.27.3\n');
  writeFileSync(paths.stamp, JSON.stringify(wantedStamp(pin, '1.27.3')));
  // An unstamped build reports `dev`.
  writeFileSync(paths.binary, '#!/bin/sh\necho "wishbone dev (unknown)"\n', { mode: 0o755 });
  assert.match(builtServerProblem(folder), /reports "wishbone dev \(unknown\)", and the pin needs "wishbone 2\.2\.0\+7773ada \(7773ada\)"/);

  writeFileSync(paths.binary, '#!/bin/sh\necho "wishbone 2.2.0+7773ada (7773ada)"\n', { mode: 0o755 });
  assert.equal(builtServerProblem(folder), null);

  // Another Go, or another recipe, is another build.
  writeFileSync(paths.stamp, JSON.stringify(wantedStamp(pin, '1.27.2')));
  assert.match(builtServerProblem(folder), /built from another pin, Go, or recipe/);
});
