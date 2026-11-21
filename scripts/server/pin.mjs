// The pinned test server: what the pin file says, and where its build lives.
//
// The pin file holds the server's release tag and that tag's commit. It changes in one commit with the copy of
// the server's OpenAPI document beside it, and the app's minimum server version. See "A real server" in
// docs/development.md.

import { readFileSync } from 'node:fs';
import path from 'node:path';

/** The pin file, as a path from the repo's root. CI finds it by its name, `server-pin`. */
export const pinFile = 'WishboneKit/Server/server-pin.json';

/** The copy of the pinned server's OpenAPI document, as a path from the repo's root. */
export const openAPIFile = 'WishboneKit/Server/openapi.json';

/** The folder that holds the built server and its source, one folder for each pin, as a path from the repo's root. */
export const serverDirectory = 'build/server';

/** Reads the pin from the pin file's text. */
export function parsePin(text) {
  let pin;
  try {
    pin = JSON.parse(text);
  } catch (error) {
    throw new Error(`${pinFile} is not JSON: ${error.message}`);
  }
  const { repository, tag, commit } = pin ?? {};
  if (typeof repository !== 'string' || !repository.startsWith('https://')) {
    throw new Error(`${pinFile}: "repository" must be an https:// address, so that the fetch needs no SSH key`);
  }
  if (typeof tag !== 'string' || !/^v\d+\.\d+\.\d+$/.test(tag)) {
    throw new Error(`${pinFile}: "tag" must be a release tag, such as v2.2.0`);
  }
  if (typeof commit !== 'string' || !/^[0-9a-f]{40}$/.test(commit)) {
    throw new Error(`${pinFile}: "commit" must be the tag's full commit SHA`);
  }
  return { repository, tag, commit };
}

/** Reads the pin of the checkout at `root`. */
export function readPin(root) {
  return parsePin(readFileSync(path.join(root, pinFile), 'utf8'));
}

/** The commit as the server's release stamps it: its first 7 characters. */
export function shortCommit(pin) {
  return pin.commit.slice(0, 7);
}

/** The version that the pinned server reports, as its release image does: `2.2.0+7773ada`. */
export function stampedVersion(pin) {
  return `${pin.tag.slice(1)}+${shortCommit(pin)}`;
}

/** The name of the pin's folder under `build/server/`. The harness in `TestSupport` builds the same name. */
export function pinKey(pin) {
  return `${pin.tag}-${shortCommit(pin)}`;
}

/** Where the pin's build lives in the checkout at `root`. */
export function buildPaths(root, pin) {
  const directory = path.join(root, serverDirectory, pinKey(pin));
  return {
    directory,
    source: path.join(directory, 'src'),
    binary: path.join(directory, 'wishbone'),
    stamp: path.join(directory, 'stamp.json'),
  };
}

/**
 * The Go version that builds the source, from its `go.mod`: the `toolchain` line when it has one, or else the
 * `go` line.
 */
export function goVersion(goMod) {
  const toolchain = goMod.match(/^toolchain\s+go(\d+\.\d+(?:\.\d+)?)\s*$/m)?.[1];
  const language = goMod.match(/^go\s+(\d+\.\d+(?:\.\d+)?)\s*$/m)?.[1];
  const version = toolchain ?? language;
  if (version === undefined) throw new Error("the server's go.mod names no Go version");
  return version;
}
