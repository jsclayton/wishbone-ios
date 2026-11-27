// `just gate`: every check that a pull request must pass. See "The gate" in docs/development.md.
//
// Its last line is the result, for example `GATE PASS package=34 hosted=0 ui=0 · 1m12s`.
//
// `--part=<name>` runs one part of the gate, as a job of the dispatched Gate run in CI does (parts.mjs). A part
// holds no count against the floor, because its counts are only some of the gate's: it writes its record to
// `build/gate/part-<name>.json`, and the sum of the parts holds the counts against the floor.

import { execFileSync } from 'node:child_process';
import path from 'node:path';
import process from 'node:process';

import { readFloor, runGate } from './gate.mjs';
import { writePart } from './parts.mjs';
import { slotDirectory } from './slot.mjs';
import { gateSteps } from './steps.mjs';

const minute = 60_000;
const root = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim();
const gateDirectory = path.join(root, 'build', 'gate');
const runDirectory = path.join(gateDirectory, 'run');
const floorFile = path.join(root, 'scripts', 'gate', 'floor.json');

const interrupt = new AbortController();
for (const name of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(name, () => interrupt.abort());

let ok = false;
try {
  const args = process.argv.slice(2);
  const unknown = args.filter((arg) => !arg.startsWith('--part='));
  if (unknown.length > 0) throw new Error(`unknown argument ${unknown.join(', ')}. The gate takes only --part=<name>`);
  const part = args.at(-1)?.slice('--part='.length);
  const result = await runGate({
    steps: gateSteps({ root, runDirectory, part }),
    floor: readFloor(floorFile),
    part,
    root,
    runDirectory,
    slotDirectory: slotDirectory(),
    timesFile: path.join(gateDirectory, 'times.jsonl'),
    floorFile: path.relative(root, floorFile),
    // The budget is for a warm run on the maintainer's laptop. A CI runner starts cold.
    budgetMs: process.env.CI ? Infinity : 5 * minute,
    owner: `the gate in ${root} (process ${process.pid})`,
    signal: interrupt.signal,
  });
  ok = result.ok;
  if (part !== undefined) {
    const { line, at, totalMs, counts, names } = result;
    writePart(path.join(gateDirectory, `part-${part}.json`), { part, ok, line, at, totalMs, counts, ui: names.ui ?? [] });
  }
} catch (error) {
  console.log(`GATE FAIL before step 1: ${error.message}`);
}
process.exit(ok ? 0 : 1);
