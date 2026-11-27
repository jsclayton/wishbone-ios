// Starts the boot of the gate's own simulator, and returns before the boot ends. CI's journeys jobs run it once
// they have the build and the caches, just before the gate, so that the simulator's first boot on a new runner goes
// on while the gate starts. On 2026-11-26 that boot took 1m16s, and then 2m45s before its status bar took a change,
// and 2m02s before its settings did. The simulator step then finds it booted, or booting, and waits for it as it
// always does. Beside the boot, a download is slow: the build's download took 165 s to 479 s in each shard that
// booted, and 3 s to 11 s in the shard that didn't, in 12 Gate runs (ci.yml has the runs).
//
// It makes the simulator when the runner has none, as the simulator step does, so the step uses this one.
//
// `node scripts/gate/boot.mjs <shard>` boots nothing for the shard that builds the package and runs its tests
// first (parts.mjs): beside a first boot, that build took more than its limit of 8 minutes in run 45893856729,
// where it took 2m23s on a quiet runner. That shard's simulator step boots the simulator when the package is done.

import { spawn } from 'node:child_process';
import process from 'node:process';

import { shardNamed } from './parts.mjs';
import { findOrMakeSimulator } from './simulator.mjs';

const shard = process.argv[2] === undefined ? undefined : shardNamed(process.argv[2]);
if (shard?.package) {
  console.log(`  ${shard.name} builds the package first, so its simulator boots in its simulator step.`);
  process.exit(0);
}
const simulator = findOrMakeSimulator();
// `simctl boot` ends when the simulator has started to boot. Detached, it goes on after this script ends.
spawn('xcrun', ['simctl', 'boot', simulator], { detached: true, stdio: 'ignore' }).unref();
console.log(`✓ Started the boot of the gate's simulator (${simulator})`);
