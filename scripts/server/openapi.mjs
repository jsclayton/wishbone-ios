// `just server-openapi`: takes the copy of the pinned server's OpenAPI document.
//
// It starts the built server with an empty data folder, reads the document that it serves, and writes it to the
// copy's file. Run it when the pin moves. The contract test holds the copy against the pinned server.

import { execFileSync, spawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

import { buildServer } from './build.mjs';
import { buildPaths, openAPIFile, readPin } from './pin.mjs';

/** A port that nothing listens on, right now. */
function freePort() {
  return new Promise((resolve, reject) => {
    const probe = createServer();
    probe.once('error', reject);
    probe.listen(0, () => {
      const { port } = probe.address();
      probe.close(() => resolve(port));
    });
  });
}

/** Reads the OpenAPI document from the built server of the checkout at `root`. */
async function servedDocument(root) {
  const { binary } = buildPaths(root, readPin(root));
  const data = mkdtempSync(path.join(tmpdir(), 'wishbone-openapi-'));
  const port = await freePort();
  const env = { PATH: process.env.PATH, TZ: 'UTC', WISHBONE_PORT: String(port), WISHBONE_PUBLIC_URL: `http://localhost:${port}`, WISHBONE_DATA_DIR: data, WISHBONE_LISTEN_ADDRESS: '127.0.0.1' };
  const server = spawn(binary, ['serve'], { cwd: data, env, stdio: 'ignore' });
  const exited = new Promise((resolve) => server.once('exit', resolve));
  try {
    for (let tries = 0; tries < 100; tries += 1) {
      if (server.exitCode !== null) throw new Error(`the server ended with ${server.exitCode} before it answered`);
      const answer = await fetch(`http://127.0.0.1:${port}/api/v2/openapi`).catch(() => null);
      if (answer?.ok) return await answer.json();
      await sleep(100);
    }
    throw new Error('the server gave no document in 10 seconds');
  } finally {
    server.kill('SIGTERM');
    await exited;
    rmSync(data, { recursive: true, force: true });
  }
}

const root = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8', cwd: path.dirname(fileURLToPath(import.meta.url)) }).trim();
try {
  const { version } = buildServer(root);
  const document = await servedDocument(root);
  writeFileSync(path.join(root, openAPIFile), `${JSON.stringify(document, null, 2)}\n`);
  console.log(`✓ ${openAPIFile} is the OpenAPI document of the test server ${version}`);
} catch (error) {
  console.error(`✗ ${openAPIFile}: ${error.message}`);
  process.exit(1);
}
