import assert from 'node:assert/strict';
import { test } from 'node:test';

import { acknowledgements, fileText, licenseFile, packageName } from './acknowledgements.mjs';

const pin = (location, revision = 'a'.repeat(40)) => ({ identity: packageName(location).toLowerCase(), location, state: { revision, version: '1.0.0' } });

test("a package's name comes from where it comes from", () => {
  assert.equal(packageName('https://github.com/groue/GRDB.swift.git'), 'GRDB.swift');
  assert.equal(packageName('https://github.com/getsentry/sentry-cocoa'), 'sentry-cocoa');
  assert.equal(packageName('https://github.com/getsentry/sentry-cocoa.git/'), 'sentry-cocoa');
});

test('the license file is found by its name, in any case, with or without an extension', () => {
  assert.equal(licenseFile(['README.md', 'LICENSE', 'Package.swift']), 'LICENSE');
  assert.equal(licenseFile(['LICENSE.md', 'Sources']), 'LICENSE.md');
  assert.equal(licenseFile(['license.txt']), 'license.txt');
  assert.equal(licenseFile(['LICENCE']), 'LICENCE');
  assert.equal(licenseFile(['COPYING']), 'COPYING');
  assert.equal(licenseFile(['README.md', 'LICENSES', 'LICENSE-notes.md']), null);
});

test('there is one entry for each pin, by name, with the whole license text', () => {
  const resolved = { pins: [pin('https://github.com/getsentry/sentry-cocoa.git', 'b'.repeat(40)), pin('https://github.com/groue/GRDB.swift.git')] };
  const texts = { 'GRDB.swift': 'Copyright (C) Gwendal Roué\r\n\r\nPermission is hereby granted\r\n', 'sentry-cocoa': '\nThe MIT License (MIT)\n\n' };
  const asked = [];
  const entries = acknowledgements(resolved, (asked_pin, name) => {
    asked.push(`${name}@${asked_pin.state.revision[0]}`);
    return texts[name];
  });
  assert.deepEqual(entries, [
    { name: 'GRDB.swift', license: 'Copyright (C) Gwendal Roué\n\nPermission is hereby granted' },
    { name: 'sentry-cocoa', license: 'The MIT License (MIT)' },
  ]);
  // Each license is read at its pin's commit.
  assert.deepEqual(asked.sort(), ['GRDB.swift@a', 'sentry-cocoa@b']);
});

test('a package whose license can not be read stops the script', () => {
  const resolved = { pins: [pin('https://github.com/groue/GRDB.swift.git')] };
  assert.throws(() => acknowledgements(resolved, () => { throw new Error('GRDB.swift is not at its pinned commit'); }), /not at its pinned commit/);
});

test('the file is the same text for the same pins, and ends with a new line', () => {
  const entries = [{ name: 'GRDB.swift', license: 'MIT' }];
  assert.equal(fileText(entries), '[\n  {\n    "name": "GRDB.swift",\n    "license": "MIT"\n  }\n]\n');
  assert.equal(fileText(acknowledgements({}, () => '')), '[]\n');
});
