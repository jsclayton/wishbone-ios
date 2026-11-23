// A String Catalog (`.xcstrings`) is one JSON file, with its keys in order. Two branches that each add a key in
// the same place conflict as text, though their keys don't. This module merges two catalogs key by key, and
// writes the result as Xcode's `xcstringstool` writes it, so a merge never reorders or reformats the file.

import { isDeepStrictEqual } from 'node:util';

// Xcode orders keys by their Unicode code points, which is the order of their UTF-8 bytes. JavaScript's own
// sort compares UTF-16 code units, which puts a character past U+FFFF (an emoji) before U+E000 to U+FFFF.
function compareKeys(a, b) {
  return Buffer.compare(Buffer.from(a, 'utf8'), Buffer.from(b, 'utf8'));
}

// `xcstringstool` writes ` : ` between a key and its value, two spaces for each level, a blank line inside an
// empty object, and no newline at the end. It escapes as JSON.stringify does, and leaves `/` as it is.
export function formatCatalog(value) {
  return write(value, '');
}

function write(value, indent) {
  if (Array.isArray(value)) {
    const inner = `${indent}  `;
    if (value.length === 0) return '[\n\n' + indent + ']';
    return '[\n' + value.map((item) => inner + write(item, inner)).join(',\n') + '\n' + indent + ']';
  }
  if (value !== null && typeof value === 'object') {
    const inner = `${indent}  `;
    const keys = Object.keys(value).sort(compareKeys);
    if (keys.length === 0) return '{\n\n' + indent + '}';
    const lines = keys.map((key) => `${inner}${JSON.stringify(key)} : ${write(value[key], inner)}`);
    return '{\n' + lines.join(',\n') + '\n' + indent + '}';
  }
  return JSON.stringify(value);
}

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

// A three-way merge of two JSON values, `ours` and `theirs`, from their common `base`. `undefined` is a key
// that isn't there. Where only one side changed a value, that side's value wins. Where both changed an object,
// the merge goes into its keys. So two branches that add different strings, or change different parts of one
// string, both keep their changes. Where both changed one value in different ways, `conflicts` gets its path,
// and the result keeps ours.
function mergeValues(base, ours, theirs, path, conflicts) {
  if (isDeepStrictEqual(ours, theirs)) return ours;
  if (isDeepStrictEqual(base, ours)) return theirs;
  if (isDeepStrictEqual(base, theirs)) return ours;
  if (isObject(ours) && isObject(theirs) && (base === undefined || isObject(base))) {
    const from = base ?? {};
    const merged = {};
    for (const key of new Set([...Object.keys(ours), ...Object.keys(theirs)])) {
      const value = mergeValues(from[key], ours[key], theirs[key], [...path, key], conflicts);
      if (value !== undefined) merged[key] = value;
    }
    return merged;
  }
  conflicts.push(path);
  return ours;
}

// Merges the texts of three catalogs. It returns the merged text, and the path of each value that both sides
// changed in different ways. It throws when a text isn't JSON.
export function mergeCatalogs(baseText, oursText, theirsText) {
  // A file that one side added has an empty base.
  const base = baseText.trim() === '' ? {} : JSON.parse(baseText);
  const ours = JSON.parse(oursText);
  const theirs = JSON.parse(theirsText);
  const conflicts = [];
  const merged = mergeValues(base, ours, theirs, [], conflicts);
  return { text: formatCatalog(merged), conflicts };
}
