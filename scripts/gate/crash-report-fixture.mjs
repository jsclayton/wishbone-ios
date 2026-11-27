// Writes the text of an `.ips` crash report, in the shape that macOS writes: a header line of JSON, then the
// report. The default is the shape of the package's crash on CI on 2026-11-23 (run 45131695827 attempt 1), cut
// down to what the gate reads.

const images = {
  kernel: { name: 'libsystem_kernel.dylib', path: '/usr/lib/system/libsystem_kernel.dylib' },
  c: { name: 'libsystem_c.dylib', path: '/usr/lib/system/libsystem_c.dylib' },
  network: { name: 'CFNetwork', path: '/System/Library/Frameworks/CFNetwork.framework/Versions/A/CFNetwork' },
  pthread: { name: 'libsystem_pthread.dylib', path: '/usr/lib/system/libsystem_pthread.dylib' },
  dispatch: { name: 'libdispatch.dylib', path: '/usr/lib/system/libdispatch.dylib' },
  dyld: { name: 'dyld_sim', path: '/Library/Developer/CoreSimulator/Volumes/iOS/usr/lib/dyld_sim' },
  cf: { name: 'CoreFoundation', path: '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation' },
  foundation: { name: 'Foundation', path: '/System/Library/Frameworks/Foundation.framework/Foundation' },
  uikit: { name: 'UIKitCore', path: '/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore' },
  accessibility: { name: 'libAccessibility.dylib', path: '/usr/lib/libAccessibility.dylib' },
  xctestCore: { name: 'XCTestCore', path: '/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks/XCTestCore.framework/XCTestCore' },
  xcui: { name: 'XCUIAutomation', path: '/Applications/Xcode.app/Contents/Developer/Library/Frameworks/XCUIAutomation.framework/XCUIAutomation' },
  xctest: { name: 'XCTest', path: '/Applications/Xcode.app/Contents/Developer/Library/Frameworks/XCTest.framework/XCTest' },
};

/** The crashed thread's frames, top first, of the crash on CI. */
export const conditionerCrash = [
  { symbol: '__pthread_kill', image: 'kernel' },
  { symbol: 'abort', image: 'c' },
  { symbol: '-[__NSURLSessionLocal taskForClassInfo:]', image: 'network' },
  { symbol: 'NetworkConditioner.Core.forward(_:)', image: 'own', file: 'NetworkConditioner.swift', line: 520 },
  { symbol: 'NetworkConditioner.Core.serve(_:)', image: 'own', file: 'NetworkConditioner.swift', line: 475 },
  { symbol: 'closure #2 in NetworkConditioner.Core.accept(_:)', image: 'own', file: 'NetworkConditioner.swift', line: 438 },
  { symbol: 'partial apply for closure #2 in NetworkConditioner.Core.accept(_:)', image: 'own', file: '/<compiler-generated>' },
];

/**
 * The stalled wait of the journeys' test runner on CI on 2026-11-27 (run 45986369104 attempt 1, journeys-1), cut
 * down: XCTest's stall handler aborted the runner, while its main thread loaded UIKit's accessibility bundle inside
 * XCTest's wait for accessibility to load, before the first test.
 */
export const stalledWaitCrash = {
  queue: 'com.apple.dt.async-test-waiter-stall',
  frames: [
    { symbol: '__pthread_kill', image: 'kernel' },
    { symbol: 'pthread_kill', image: 'pthread' },
    { symbol: 'abort', image: 'c' },
    { symbol: '-[XCTWaiter(StallHandling) handleStalledWait:]', image: 'xctestCore' },
    { symbol: '__52-[XCTWaiter(StallHandling) handleStalledWait:after:]_block_invoke', image: 'xctestCore' },
    { symbol: '_dispatch_client_callout', image: 'dispatch' },
  ],
  main: [
    { symbol: 'mach_o::Header::fromDyldMapped(mach_header const*)', image: 'dyld' },
    { symbol: 'dyld4::JustInTimeLoader::loadDependents(Diagnostics&, dyld4::RuntimeState&, dyld4::Loader::LoadOptions const&)', image: 'dyld' },
    { symbol: 'dyld4::JustInTimeLoader::loadDependents(Diagnostics&, dyld4::RuntimeState&, dyld4::Loader::LoadOptions const&)', image: 'dyld' },
    { symbol: 'dyld4::APIs::dlopen_from(char const*, int, void*)', image: 'dyld' },
    { symbol: '_CFBundleDlfcnLoadBundle', image: 'cf' },
    { symbol: '-[NSBundle loadAndReturnError:]', image: 'foundation' },
    { symbol: '-[UIApplication(UIKitApplicationAccessibility) _accessibilityBundlePrincipalClass]', image: 'uikit' },
    { symbol: '-[UIApplication(UIKitApplicationAccessibility) _updateApplicationAccessibility]', image: 'uikit' },
    { symbol: '-[UIApplication(UIKitApplicationAccessibility) _accessibilityInit]', image: 'uikit' },
    { symbol: '__CFNOTIFICATIONCENTER_IS_CALLING_OUT_TO_AN_OBSERVER__', image: 'cf' },
    { symbol: '___axsHandlePrefChanged_block_invoke', image: 'accessibility' },
    { symbol: '_dispatch_main_queue_drain', image: 'dispatch' },
    { symbol: '__CFRunLoopRun', image: 'cf' },
    { symbol: '+[XCTWaiter _synchronouslyWaitForTimeInterval:]', image: 'xctestCore' },
    { symbol: '-[XCTWaiter waitForExpectations:timeout:enforceOrder:]', image: 'xctestCore' },
    { symbol: '-[XCTFuture value]', image: 'xctestCore' },
    { symbol: '-[XCAXClient_iOS _loadAccessibility:]', image: 'xcui' },
    { symbol: '-[XCAXClient_iOS loadAccessibility:]', image: 'xcui' },
    { symbol: 'XCUIInitializeForUITesting', image: 'xctest' },
    { symbol: '-[XCTestDriver _runTests]', image: 'xctestCore' },
  ],
};

/**
 * A crash report of `process`, whose test binary is `binary`. Each frame names its binary: `own` for the test
 * binary, which is in the user's folder, or a key of `images` for one of the system's. `frames` are the crashed
 * thread's, on the dispatch queue `queue` when it has one, and `main` the main thread's.
 */
export function crashReport({
  process = 'swiftpm-testing-helper',
  binary = 'WishboneSessionTests',
  signal = 'SIGABRT',
  frames = conditionerCrash,
  queue,
  main = [{ symbol: 'mach_msg2_trap', image: 'kernel' }],
} = {}) {
  const used = [{ name: process, path: `/Applications/Xcode.app/Contents/Developer/usr/libexec/${process}` }, { name: binary, path: `/Users/USER/*/${binary}` }];
  const index = (key) => {
    if (key === 'own') return 1;
    const found = used.findIndex((image) => image.name === images[key].name);
    if (found >= 0) return found;
    used.push(images[key]);
    return used.length - 1;
  };
  const framesOf = (frames) => frames.map(({ symbol, image, file, line }) => ({
    imageOffset: 1024,
    symbol,
    symbolLocation: 8,
    imageIndex: index(image),
    ...(file === undefined ? {} : { sourceFile: file }),
    ...(line === undefined ? {} : { sourceLine: line }),
  }));
  const mainFrames = framesOf(main);
  const threadFrames = framesOf(frames);
  const header = { app_name: process, timestamp: '2026-11-23 07:40:05.00 +0000', bug_type: '309', name: process };
  const report = {
    procName: process,
    procPath: used[0].path,
    exception: { type: 'EXC_CRASH', signal, codes: '0x0000000000000000, 0x0000000000000000' },
    faultingThread: 1,
    threads: [
      { id: 1, queue: 'com.apple.main-thread', frames: mainFrames },
      { id: 2, triggered: true, ...(queue === undefined ? {} : { queue }), frames: threadFrames },
    ],
    usedImages: used,
  };
  return `${JSON.stringify(header)}\n${JSON.stringify(report, null, 2)}\n`;
}
