// Writes the text of an `.ips` crash report, in the shape that macOS writes: a header line of JSON, then the
// report. The default is the shape of the package's crash on CI on 2026-11-23 (run 45131695827 attempt 1), cut
// down to what the gate reads.

const images = {
  kernel: { name: 'libsystem_kernel.dylib', path: '/usr/lib/system/libsystem_kernel.dylib' },
  c: { name: 'libsystem_c.dylib', path: '/usr/lib/system/libsystem_c.dylib' },
  network: { name: 'CFNetwork', path: '/System/Library/Frameworks/CFNetwork.framework/Versions/A/CFNetwork' },
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
 * A crash report of `process`, whose test binary is `binary`. Each frame names its binary: `own` for the test
 * binary, which is in the user's folder, or a key of `images` for one of the system's.
 */
export function crashReport({ process = 'swiftpm-testing-helper', binary = 'WishboneSessionTests', signal = 'SIGABRT', frames = conditionerCrash } = {}) {
  const used = [{ name: process, path: `/Applications/Xcode.app/Contents/Developer/usr/libexec/${process}` }, { name: binary, path: `/Users/USER/*/${binary}` }];
  const index = (key) => {
    if (key === 'own') return 1;
    const found = used.findIndex((image) => image.name === images[key].name);
    if (found >= 0) return found;
    used.push(images[key]);
    return used.length - 1;
  };
  const threadFrames = frames.map(({ symbol, image, file, line }) => ({
    imageOffset: 1024,
    symbol,
    symbolLocation: 8,
    imageIndex: index(image),
    ...(file === undefined ? {} : { sourceFile: file }),
    ...(line === undefined ? {} : { sourceLine: line }),
  }));
  const header = { app_name: process, timestamp: '2026-11-23 07:40:05.00 +0000', bug_type: '309', name: process };
  const report = {
    procName: process,
    procPath: used[0].path,
    exception: { type: 'EXC_CRASH', signal, codes: '0x0000000000000000, 0x0000000000000000' },
    faultingThread: 1,
    threads: [{ id: 1, frames: [{ imageOffset: 2048, symbol: 'mach_msg2_trap', imageIndex: index('kernel') }] }, { id: 2, triggered: true, frames: threadFrames }],
    usedImages: used,
  };
  return `${JSON.stringify(header)}\n${JSON.stringify(report, null, 2)}\n`;
}
