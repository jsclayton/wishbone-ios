// `just server`: fetches the pinned Wishbone server and builds it, or reuses the built one.
//
// The tests run against this server (see "A real server" in docs/development.md, and ADR 0007):
// - The source comes over HTTPS, at the pin's tag. The fetch fails when the tag is not at the pin's commit.
// - The build has the `e2e` tag, and the version that the release of that tag reports. An unstamped build
//   reports `dev`.
// - Go's version comes from the source's `go.mod`, through mise.
// - The build is reused until the pin, Go's version, or the recipe below changes.

import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';

import { buildPaths, goVersion, pinKey, readPin, serverDirectory, shortCommit, stampedVersion } from './pin.mjs';

/**
 * The arguments of `go build`, as the server's own `just build-e2e` gives them. The stamp holds them, so a change
 * here builds the server again.
 */
function buildArguments(pin, { time, output }) {
  const flags = [
    '-s',
    '-w',
    `-X 'main.version=${stampedVersion(pin)}'`,
    `-X 'main.commit=${shortCommit(pin)}'`,
    `-X 'main.buildTime=${time}'`,
  ];
  return ['build', '-trimpath', '-tags', 'e2e', `-ldflags=${flags.join(' ')}`, '-o', output, './cmd/wishbone'];
}

/** What a build is made from. A built server is reused only while its stamp equals this. */
export function wantedStamp(pin, go) {
  return { ...pin, version: stampedVersion(pin), go, recipe: buildArguments(pin, { time: '', output: '' }) };
}

/** The first line of what `wishbone version` prints for the pin. */
function versionLine(pin) {
  return `wishbone ${stampedVersion(pin)} (${shortCommit(pin)})`;
}

/**
 * Why the checkout at `root` has no built server for its pin, or null when it has one.
 *
 * The gate's server step calls this after `just server`, and so does the build, to reuse a built server.
 */
export function builtServerProblem(root) {
  const pin = readPin(root);
  const paths = buildPaths(root, pin);
  const name = path.relative(root, paths.directory);
  if (!existsSync(paths.binary)) return `${name} has no built server`;
  let stamp;
  let go;
  try {
    stamp = JSON.parse(readFileSync(paths.stamp, 'utf8'));
    go = goVersion(readFileSync(path.join(paths.source, 'go.mod'), 'utf8'));
  } catch (error) {
    return `${name} is not whole: ${error.message}`;
  }
  if (!isDeepStrictEqual(stamp, wantedStamp(pin, go))) return `${name} was built from another pin, Go, or recipe`;
  const ran = spawnSync(paths.binary, ['version'], { encoding: 'utf8' });
  const line = (ran.stdout ?? '').trim();
  if (ran.status !== 0 || line !== versionLine(pin)) {
    return `${name}/wishbone reports "${line}", and the pin needs "${versionLine(pin)}"`;
  }
  return null;
}

function isAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === 'EPERM';
  }
}

/** Removes every build but the pin's, so that moving the pin deletes the old one. A build under way stays. */
function removeOtherBuilds(root, pin) {
  const directory = path.join(root, serverDirectory);
  for (const name of existsSync(directory) ? readdirSync(directory) : []) {
    if (name === pinKey(pin)) continue;
    const builder = Number(name.match(/^\.work-(\d+)$/)?.[1]);
    if (Number.isInteger(builder) && isAlive(builder)) continue;
    rmSync(path.join(directory, name), { recursive: true, force: true });
  }
}

/** Runs a command, and throws with its output when it fails. */
function run(file, args, { what, ...options }) {
  const ran = spawnSync(file, args, { encoding: 'utf8', ...options });
  if (ran.error?.code === 'ENOENT') throw new Error(`${what}: ${file} is not installed. See "Prerequisites" in docs/development.md`);
  if (ran.error) throw new Error(`${what}: ${ran.error.message}`);
  if (ran.status !== 0) throw new Error(`${what}: ${file} ended with ${ran.status ?? ran.signal}\n${ran.stdout}${ran.stderr}`.trimEnd());
  return ran.stdout.trim();
}

/** Fetches the pin's source into `source`, over HTTPS, and checks that the tag is at the pin's commit. */
function fetchSource(pin, source) {
  // The user's git settings stay out of it. A setting there can turn an https:// address into an SSH one, and
  // an SSH fetch needs a key. The server's repo is public, so the fetch needs no sign-in and never asks.
  const env = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null', GIT_TERMINAL_PROMPT: '0' };
  const git = (args, what) => run('git', args, { what, env, cwd: source });
  mkdirSync(source, { recursive: true });
  git(['init', '--quiet'], 'the fetch of the server');
  git(['fetch', '--quiet', '--depth', '1', pin.repository, `refs/tags/${pin.tag}`], `the fetch of ${pin.tag} from ${pin.repository}`);
  const fetched = git(['rev-parse', 'FETCH_HEAD^{commit}'], 'the fetch of the server');
  if (fetched !== pin.commit) throw new Error(`the tag ${pin.tag} is at ${fetched}, and the pin says ${pin.commit}`);
  git(['-c', 'advice.detachedHead=false', 'checkout', '--quiet', '--detach', 'FETCH_HEAD'], 'the checkout of the server');
  rmSync(path.join(source, '.git'), { recursive: true, force: true });
}

/** Builds the source in `source` to `output`, with the Go that its `go.mod` names. */
function compile(pin, { root, source, output, go }) {
  // The server embeds its web app's build. The app's tests use only the API, so a placeholder page is enough,
  // as it is for the server's own Go tests (`just embed-placeholder` there).
  const embedded = path.join(source, 'internal', 'server', 'web', 'dist');
  if (!existsSync(path.join(embedded, 'index.html'))) {
    mkdirSync(embedded, { recursive: true });
    writeFileSync(path.join(embedded, 'index.html'), '<!doctype html><title>wishbone</title><h1>wishbone</h1>\n');
  }
  const time = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
  // mise gives the Go that the source asks for, and installs it when the machine doesn't have it. Go must not
  // then fetch another toolchain by itself, and the user's Go settings stay out of the build.
  const env = { ...process.env, CGO_ENABLED: '0', GOTOOLCHAIN: 'local', GOFLAGS: '', GOWORK: 'off' };
  run('mise', ['exec', `go@${go}`, '--', 'go', '-C', source, ...buildArguments(pin, { time, output })], {
    what: `the build of the server with Go ${go}`,
    env,
    cwd: root,
  });
}

/**
 * Builds the pinned server of the checkout at `root`, or reuses the built one. Returns `{ reused, version, go }`.
 *
 * The build is made in a folder of its own and moved into place whole, so a build that fails or is stopped
 * leaves no half-built server.
 */
export function buildServer(root) {
  const pin = readPin(root);
  const paths = buildPaths(root, pin);
  removeOtherBuilds(root, pin);
  if (builtServerProblem(root) === null) return { reused: true, version: stampedVersion(pin), go: wantedGo(paths) };

  const work = path.join(root, serverDirectory, `.work-${process.pid}`);
  rmSync(work, { recursive: true, force: true });
  try {
    const source = path.join(work, 'src');
    fetchSource(pin, source);
    const go = goVersion(readFileSync(path.join(source, 'go.mod'), 'utf8'));
    compile(pin, { root, source, output: path.join(work, 'wishbone'), go });
    writeFileSync(path.join(work, 'stamp.json'), `${JSON.stringify(wantedStamp(pin, go), null, 2)}\n`);
    rmSync(paths.directory, { recursive: true, force: true });
    try {
      renameSync(work, paths.directory);
    } catch (error) {
      // Another build of the same pin, in the same checkout, got there first. Its server is checked below.
      if (error.code !== 'ENOTEMPTY' && error.code !== 'EEXIST') throw error;
    }
    const problem = builtServerProblem(root);
    if (problem !== null) throw new Error(problem);
    return { reused: false, version: stampedVersion(pin), go };
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

function wantedGo(paths) {
  return goVersion(readFileSync(path.join(paths.source, 'go.mod'), 'utf8'));
}

if (import.meta.main) {
  const root = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8', cwd: path.dirname(fileURLToPath(import.meta.url)) }).trim();
  const started = Date.now();
  try {
    const { reused, version, go } = buildServer(root);
    const where = path.relative(root, buildPaths(root, readPin(root)).directory);
    const seconds = Math.round((Date.now() - started) / 1000);
    console.log(reused ? `✓ Test server ${version}: reused ${where}` : `✓ Test server ${version}: built with Go ${go} in ${where} (${seconds}s)`);
  } catch (error) {
    console.error(`✗ Test server: ${error.message}`);
    process.exit(1);
  }
}
