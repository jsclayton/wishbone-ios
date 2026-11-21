// The docs check that `just lint` runs. It reports, and changes nothing.
//
// - Every relative link in a Markdown file leads to a file that exists. A link with a `#fragment` leads to a
//   heading in that file.
// - The ADR index (docs/adr/README.md) and the screen index (docs/screens/README.md, under "Index") each link
//   every file in their folder, and nothing else.
//
// It reads the Markdown files that git tracks, and the new ones that git doesn't ignore.

import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const root = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim();
const problems = [];

/** The Markdown files to check, as paths from the repo's root. */
function markdownFiles() {
  const listed = execFileSync('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', '*.md'], {
    cwd: root,
    encoding: 'utf8',
  });
  return listed
    .split('\0')
    .filter((file) => file !== '' && existsSync(path.join(root, file)))
    .sort();
}

/** The file's lines, with fenced code blocks and inline code blanked, so that an example is not read as a link. */
function proseLines(file) {
  let fence = null;
  return readFileSync(path.join(root, file), 'utf8')
    .split('\n')
    .map((line) => {
      const marker = line.match(/^\s*(`{3,}|~{3,})/)?.[1];
      if (fence !== null) {
        if (marker !== undefined && marker.startsWith(fence)) fence = null;
        return '';
      }
      if (marker !== undefined) {
        fence = marker;
        return '';
      }
      return line.replace(/`[^`]*`/g, (code) => ' '.repeat(code.length));
    });
}

/** The fragment that GitHub gives a heading. */
function slug(heading) {
  return heading
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1') // a link keeps its text
    .replace(/[*`]/g, '')
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\p{M}\p{Pc}\- ]/gu, '')
    .replace(/ /g, '-');
}

const fragmentsByFile = new Map();

/** Every fragment that a link to the file can name. A heading that repeats gets `-1`, `-2`, and so on. */
function fragments(file) {
  if (!fragmentsByFile.has(file)) {
    const found = new Set();
    const seen = new Map();
    let fence = null;
    for (const line of readFileSync(path.join(root, file), 'utf8').split('\n')) {
      const marker = line.match(/^\s*(`{3,}|~{3,})/)?.[1];
      if (fence !== null) {
        if (marker !== undefined && marker.startsWith(fence)) fence = null;
        continue;
      }
      if (marker !== undefined) {
        fence = marker;
        continue;
      }
      const heading = line.match(/^#{1,6}\s+(.*?)\s*#*\s*$/)?.[1];
      if (heading === undefined) continue;
      const base = slug(heading);
      const count = seen.get(base) ?? 0;
      seen.set(base, count + 1);
      found.add(count === 0 ? base : `${base}-${count}`);
    }
    fragmentsByFile.set(file, found);
  }
  return fragmentsByFile.get(file);
}

/** The links in a file: each with its line number and its target. */
function links(file) {
  const found = [];
  proseLines(file).forEach((line, index) => {
    for (const match of line.matchAll(/\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)/g)) {
      found.push({ line: index + 1, target: match[1] });
    }
  });
  return found;
}

function checkLinks(file) {
  for (const { line, target } of links(file)) {
    if (/^[a-z][a-z0-9+.-]*:/i.test(target)) continue; // https:, mailto:, and so on
    const [linkPath, fragment] = target.split('#', 2);
    const resolved = linkPath === '' ? file : path.normalize(path.join(path.dirname(file), decodeURIComponent(linkPath)));
    if (resolved.startsWith('..') || !existsSync(path.join(root, resolved))) {
      problems.push(`${file}:${line}: the link to ${target} leads nowhere`);
      continue;
    }
    if (fragment === undefined || fragment === '' || !resolved.endsWith('.md')) continue;
    if (statSync(path.join(root, resolved)).isFile() && !fragments(resolved).has(decodeURIComponent(fragment))) {
      problems.push(`${file}:${line}: ${resolved} has no heading for #${fragment}`);
    }
  }
}

/**
 * Checks that an index links each Markdown file in its folder once, and nothing else in the folder.
 * With `section`, only the links under that `##` heading count as the index.
 */
function checkIndex(folder, { section } = {}) {
  const index = `${folder}/README.md`;
  if (!existsSync(path.join(root, index))) {
    problems.push(`${index}: the index is missing`);
    return;
  }
  let lines = proseLines(index);
  if (section !== undefined) {
    const start = lines.findIndex((line) => line.trim() === `## ${section}`);
    if (start === -1) {
      problems.push(`${index}: there is no "## ${section}" heading`);
      return;
    }
    const length = lines.slice(start + 1).findIndex((line) => line.startsWith('## '));
    lines = lines.slice(start + 1, length === -1 ? undefined : start + 1 + length);
  }
  const linked = [];
  for (const line of lines) {
    for (const match of line.matchAll(/\]\(([^)#\s/]+\.md)(?:#[^)\s]*)?\)/g)) linked.push(match[1]);
  }
  const files = readdirSync(path.join(root, folder)).filter((name) => name.endsWith('.md') && name !== 'README.md');
  for (const name of files) {
    if (!linked.includes(name)) problems.push(`${index}: the index has no row for ${name}`);
  }
  for (const name of new Set(linked)) {
    if (!files.includes(name)) problems.push(`${index}: the index has a row for ${name}, which is not in ${folder}/`);
    if (linked.filter((other) => other === name).length > 1) problems.push(`${index}: the index has ${name} twice`);
  }
}

const files = markdownFiles();
files.forEach(checkLinks);
checkIndex('docs/adr');
checkIndex('docs/screens', { section: 'Index' });

if (problems.length > 0) {
  console.error(problems.join('\n'));
  console.error(`\n✗ The docs check found ${problems.length} problem${problems.length === 1 ? '' : 's'}.`);
  process.exit(1);
}
console.log(`✓ The docs check passed: ${files.length} Markdown files, the ADR index, and the screen index.`);
