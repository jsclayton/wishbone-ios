// Makes the license texts of the Acknowledgements screen from the pinned packages, so they never go out of date.
// See "Source code and Acknowledgements" in docs/spec.md.
//
// `just build` runs it after the build, which has fetched each package at its pinned commit. It writes one JSON
// file into the app's resources: the name and the full license text of each package that the app ships. The file
// is in git. The gate fails when the build changed it, so a commit that moves a pin holds that pin's license.

import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

/** The file that the script writes, from the checkout's root. */
export const acknowledgementsFile = 'WishboneKit/Sources/WishboneUI/Resources/Acknowledgements.json';

/** The packages that the app ships: the pins of the project. */
const resolvedFile = 'Wishbone.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved';

/** Where a build keeps the packages that it fetched, from the checkout's root. `just build` fills the first. */
const checkoutFolders = ['build/DerivedData/SourcePackages/checkouts', 'WishboneKit/.build/checkouts'];

/** A package's name, from where it comes from: `GRDB.swift` for `https://github.com/groue/GRDB.swift.git`. */
export function packageName(location) {
  return path.basename(location.replace(/\/+$/, '')).replace(/\.git$/, '');
}

/** The license file among a folder's files: `LICENSE`, also with an extension, and as `LICENCE` or `COPYING`. */
export function licenseFile(names) {
  const wanted = /^(licen[sc]e|copying)(\.(md|txt))?$/i;
  return [...names].sort().find((name) => wanted.test(name)) ?? null;
}

/**
 * The acknowledgements of the pins, by name: `[{ name, license }]`.
 *
 * `read(pin, name)` gives the package's license text at the pin's commit, and throws when it can't.
 */
export function acknowledgements(resolved, read) {
  return (resolved.pins ?? [])
    .map((pin) => {
      const name = packageName(pin.location);
      return { name, license: read(pin, name).replace(/\r\n/g, '\n').trim() };
    })
    .sort((one, other) => one.name.localeCompare(other.name));
}

/** The acknowledgements as the text of the file. */
export function fileText(entries) {
  return `${JSON.stringify(entries, null, 2)}\n`;
}

/** Reads a pin's license from the package that a build fetched, at the pin's commit. */
function readFromCheckout(root) {
  return (pin, name) => {
    const tried = [];
    for (const folder of checkoutFolders) {
      const checkout = path.join(root, folder, name);
      if (!existsSync(checkout)) continue;
      const commit = execFileSync('git', ['-C', checkout, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
      if (commit !== pin.state.revision) {
        tried.push(`${folder}/${name} is at ${commit.slice(0, 7)}`);
        continue;
      }
      const file = licenseFile(readdirSync(checkout));
      if (file === null) throw new Error(`${name} has no license file in ${folder}/${name}`);
      return readFileSync(path.join(checkout, file), 'utf8');
    }
    const why = tried.length > 0 ? tried.join(', and ') : 'no build has fetched it';
    throw new Error(`${name} is not at its pinned commit ${pin.state.revision.slice(0, 7)}: ${why}. Run 'just build' first`);
  };
}

if (import.meta.main) {
  const root = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8', cwd: path.dirname(fileURLToPath(import.meta.url)) }).trim();
  try {
    const resolved = JSON.parse(readFileSync(path.join(root, resolvedFile), 'utf8'));
    writeFileSync(path.join(root, acknowledgementsFile), fileText(acknowledgements(resolved, readFromCheckout(root))));
  } catch (error) {
    console.error(`✗ Acknowledgements: ${error.message}`);
    process.exit(1);
  }
}
