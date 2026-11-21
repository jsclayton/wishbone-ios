// Builds the tree that `xcresulttool get test-results tests` prints for a result bundle, for the gate's own
// tests. The nodes hold the fields that the gate reads, in the shape that Xcode 27.2 writes them.

const results = { pass: 'Passed', fail: 'Failed', skip: 'Skipped', known: 'Expected Failure' };
const details = { fail: 'Failure Message', skip: 'Skip Message', known: 'Expected Failure' };

/**
 * `tests` maps a test's name, such as `HostedTests.SessionKeychainTests/item()`, to how it ends: `pass`, `fail`,
 * `skip`, `known` (it passes with an expected failure), or `fail-case` (one case of a test with arguments fails).
 * `runFailed` makes Xcode fail the run whatever its tests did.
 */
export function testResults(tests, { runFailed } = {}) {
  const bundles = new Map();
  for (const [name, outcome] of Object.entries(tests)) {
    const [bundle, identifier] = [name.slice(0, name.indexOf('.')), name.slice(name.indexOf('.') + 1)];
    const suite = identifier.split('/')[0];
    const node = { durationInSeconds: 1.5, name: identifier.split('/')[1], nodeIdentifier: identifier, nodeType: 'Test Case', result: results[outcome] ?? 'Failed' };
    if (details[outcome] !== undefined) node.children = [{ name: 'planted', nodeType: details[outcome] }];
    if (outcome === 'fail-case') {
      node.children = [
        { name: '1', nodeType: 'Arguments', result: 'Passed' },
        { name: '2', nodeType: 'Arguments', result: 'Failed', children: [{ name: 'planted', nodeType: 'Failure Message' }] },
      ];
    }
    if (!bundles.has(bundle)) bundles.set(bundle, new Map());
    if (!bundles.get(bundle).has(suite)) bundles.get(bundle).set(suite, []);
    bundles.get(bundle).get(suite).push(node);
  }
  const failed = (nodes) => (nodes.some((node) => node.result === 'Failed') ? 'Failed' : 'Passed');
  const bundleNodes = [...bundles].map(([bundle, suites]) => {
    const children = [...suites].map(([suite, cases]) => ({ children: cases, name: suite, nodeType: 'Test Suite', result: failed(cases) }));
    return { children, name: bundle, nodeType: bundle.includes('Journey') ? 'UI test bundle' : 'Unit test bundle', result: failed(children) };
  });
  return {
    devices: [{ deviceName: 'Wishbone gate', platform: 'iOS Simulator' }],
    testNodes: [{ children: bundleNodes, name: 'Wishbone', nodeType: 'Test Plan', result: runFailed ? 'Failed' : failed(bundleNodes) }],
  };
}
