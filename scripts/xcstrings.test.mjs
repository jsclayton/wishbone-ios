import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import { formatCatalog, mergeCatalogs } from './xcstrings.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const catalogPath = path.join(here, '..', 'WishboneKit/Sources/WishboneUI/Resources/Localizable.xcstrings');

function catalog(strings) {
  return formatCatalog({ sourceLanguage: 'en', strings, version: '1.0' });
}

function keys(text) {
  return Object.keys(JSON.parse(text).strings);
}

const translated = (value) => ({ localizations: { en: { stringUnit: { state: 'translated', value } } } });

test('the format is the one xcstringstool writes, so the app catalog comes back byte for byte', () => {
  const text = readFileSync(catalogPath, 'utf8');
  assert.equal(formatCatalog(JSON.parse(text)), text);
});

test('keys are in code point order, as xcstringstool orders them, and escaped as it escapes them', () => {
  // The order and the escapes are xcstringstool's own, from a sync of these keys.
  const text = catalog({ '😀': {}, ﬀ: {}, éa: {}, Éa: {}, 'tab\there': {}, 'b/c "q"': { comment: 'x/y' }, a: {}, Zed: {} });
  assert.deepEqual(keys(text), ['Zed', 'a', 'b/c "q"', 'tab\there', 'Éa', 'éa', 'ﬀ', '😀']);
  assert.match(text, /"b\/c \\"q\\"" : \{\n {6}"comment" : "x\/y"\n {4}\}/);
  assert.match(text, /"tab\\there" : \{\n\n {4}\}/);
  assert.ok(!text.endsWith('\n'), 'no newline at the end');
});

test('two catalogs that add different keys in the same place merge with both, in order', () => {
  const base = catalog({ Apples: {}, Cherries: {} });
  const ours = catalog({ Apples: {}, Bananas: {}, Cherries: {} });
  const theirs = catalog({ Apples: {}, Blueberries: translated('Blueberries!'), Cherries: {} });
  // As text, the two additions conflict.
  assert.equal(textMerge(base, ours, theirs).status, 1);

  const merged = mergeCatalogs(base, ours, theirs);
  assert.deepEqual(merged.conflicts, []);
  assert.equal(merged.text, catalog({ Apples: {}, Bananas: {}, Blueberries: translated('Blueberries!'), Cherries: {} }));
});

test('a key that one side removed or changed keeps that change, and changes to different parts of one key both stay', () => {
  const base = catalog({ Gone: {}, Kept: {}, Both: translated('Both') });
  const ours = catalog({ Kept: { comment: 'ours' }, Both: { ...translated('Both'), comment: 'A comment' } });
  const theirs = catalog({ Gone: {}, Kept: {}, Both: translated('Both, again'), New: {} });
  const merged = mergeCatalogs(base, ours, theirs);
  assert.deepEqual(merged.conflicts, []);
  assert.equal(merged.text, catalog({ Both: { ...translated('Both, again'), comment: 'A comment' }, Kept: { comment: 'ours' }, New: {} }));
});

test('one value that both sides changed in different ways is a conflict, and the result keeps ours', () => {
  const base = catalog({ Key: { comment: 'base' } });
  const ours = catalog({ Key: { comment: 'ours' } });
  const theirs = catalog({ Key: { comment: 'theirs' } });
  const merged = mergeCatalogs(base, ours, theirs);
  assert.deepEqual(merged.conflicts, [['strings', 'Key', 'comment']]);
  assert.equal(merged.text, ours);
});

function textMerge(base, ours, theirs) {
  const folder = mkdtempSync(path.join(tmpdir(), 'wishbone-xcstrings-test-'));
  try {
    for (const [name, text] of Object.entries({ base, ours, theirs })) writeFileSync(path.join(folder, name), text);
    return spawnSync('git', ['merge-file', '-p', 'ours', 'base', 'theirs'], { cwd: folder });
  } finally {
    rmSync(folder, { recursive: true, force: true });
  }
}

// The driver as git runs it: registered with `--register`, named by .gitattributes, in a rebase.
test('a rebase of a branch that adds strings onto one that added others takes both, with no conflict', (t) => {
  const repo = mkdtempSync(path.join(tmpdir(), 'wishbone-xcstrings-test-'));
  t.after(() => rmSync(repo, { recursive: true, force: true }));
  // Leave out the user's own git config, which may sign each commit.
  const env = {
    ...process.env,
    GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_CONFIG_NOSYSTEM: '1',
    GIT_AUTHOR_NAME: 'Test',
    GIT_AUTHOR_EMAIL: 'test@example.com',
    GIT_COMMITTER_NAME: 'Test',
    GIT_COMMITTER_EMAIL: 'test@example.com',
  };
  const git = (...args) => execFileSync('git', args, { cwd: repo, env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  const file = path.join(repo, 'Localizable.xcstrings');
  const commit = (message) => git('commit', '-qam', message);

  git('init', '-q', '-b', 'main');
  mkdirSync(path.join(repo, 'scripts'));
  for (const name of ['xcstrings.mjs', 'xcstrings-merge.mjs']) copyFileSync(path.join(here, name), path.join(repo, 'scripts', name));
  copyFileSync(path.join(here, '..', '.gitattributes'), path.join(repo, '.gitattributes'));
  execFileSync(process.execPath, ['scripts/xcstrings-merge.mjs', '--register'], { cwd: repo, env });
  writeFileSync(file, catalog({ Apples: {}, Cherries: {} }));
  git('add', '.');
  commit('base');

  git('switch', '-q', '-c', 'feature');
  writeFileSync(file, catalog({ Apples: {}, Bananas: {}, Cherries: {} }));
  commit('add bananas');
  git('switch', '-q', 'main');
  writeFileSync(file, catalog({ Apples: {}, Blueberries: {}, Cherries: {} }));
  commit('add blueberries');

  // The coordinator's check before a merge, and then the rebase.
  const tree = git('merge-tree', '--write-tree', 'main', 'feature').trim();
  assert.deepEqual(keys(git('show', `${tree}:Localizable.xcstrings`)), ['Apples', 'Bananas', 'Blueberries', 'Cherries']);
  git('switch', '-q', 'feature');
  git('rebase', '-q', 'main');
  assert.equal(readFileSync(file, 'utf8'), catalog({ Apples: {}, Bananas: {}, Blueberries: {}, Cherries: {} }));
  assert.equal(git('status', '--porcelain'), '');
});
