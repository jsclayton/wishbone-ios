// Starts the boot of the gate's own simulator, and returns before the boot ends. CI's journeys jobs run it once
// their tools are installed, so that the simulator's first boot on a new runner goes on while the job gets the
// build and unpacks it. On 2026-11-26 that boot took 1m16s, and then 2m45s before its status bar took a change,
// and 2m02s before its settings did. The simulator step then finds it booted, or booting, and waits for it as it
// always does.
//
// It makes the simulator when the runner has none, as the simulator step does, so the step uses this one.

import { spawn } from 'node:child_process';

import { findOrMakeSimulator } from './simulator.mjs';

const simulator = findOrMakeSimulator();
// `simctl boot` ends when the simulator has started to boot. Detached, it goes on after this script ends.
spawn('xcrun', ['simctl', 'boot', simulator], { detached: true, stdio: 'ignore' }).unref();
console.log(`✓ Started the boot of the gate's simulator (${simulator})`);
