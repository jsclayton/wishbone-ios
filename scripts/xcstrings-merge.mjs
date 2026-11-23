// Git's merge driver for String Catalogs. `.gitattributes` names it for `*.xcstrings`, and `--register` writes
// it to the clone's git config, which every worktree of the clone shares. `pnpm install` and `just build` both
// register it (see "The String Catalog" in docs/development.md).
//
//   node scripts/xcstrings-merge.mjs --register
//   node scripts/xcstrings-merge.mjs <base> <ours> <theirs> [<path>]
//
// Git passes three temporary files, and keeps what the driver writes to <ours>. The driver exits 0 when the
// merge is clean, and 1 when both sides changed one value in different ways, or when a file isn't JSON. Then
// git reports a conflict, as it does for any file.

import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';

import { mergeCatalogs } from './xcstrings.mjs';

// Git runs the driver with a shell, from the top of the worktree that merges, so the script is that worktree's.
const driver = 'node "$(git rev-parse --show-toplevel)/scripts/xcstrings-merge.mjs" %O %A %B %P';

if (process.argv[2] === '--register') {
  for (const [key, value] of [
    ['merge.xcstrings.name', 'String Catalog, key by key'],
    ['merge.xcstrings.driver', driver],
  ]) {
    const set = spawnSync('git', ['config', key, value], { stdio: 'inherit' });
    if (set.status !== 0) process.exit(set.status ?? 1);
  }
  process.exit(0);
}

const [basePath, oursPath, theirsPath, name = oursPath] = process.argv.slice(2);
if (!basePath || !oursPath || !theirsPath) {
  console.error('usage: node scripts/xcstrings-merge.mjs <base> <ours> <theirs> [<path>]');
  process.exit(2);
}

let result;
try {
  result = mergeCatalogs(readFileSync(basePath, 'utf8'), readFileSync(oursPath, 'utf8'), readFileSync(theirsPath, 'utf8'));
} catch (error) {
  // Not a catalog that the driver can read: merge it as text, with the usual conflict markers.
  console.error(`xcstrings merge: ${name} isn't JSON (${error.message}). Merging it as text.`);
  const text = spawnSync('git', ['merge-file', '-L', 'ours', '-L', 'base', '-L', 'theirs', oursPath, basePath, theirsPath], {
    stdio: 'inherit',
  });
  process.exit(text.status === 0 ? 0 : 1);
}

writeFileSync(oursPath, result.text);
if (result.conflicts.length > 0) {
  console.error(`xcstrings merge: both sides changed these values of ${name} in different ways. The file keeps ours:`);
  for (const path of result.conflicts) console.error(`  ${path.map((part) => JSON.stringify(part)).join(' → ')}`);
  process.exit(1);
}
