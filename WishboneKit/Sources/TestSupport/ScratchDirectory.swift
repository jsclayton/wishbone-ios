import Darwin
import Foundation
import Synchronization

/// A temporary folder for a test. It is removed when its last holder goes.
///
/// This file is the one place that names a temporary folder: a fitness test bans the system's own names for one
/// everywhere else. See "Temporary folders" in `docs/development.md`.
///
/// - Each test process has one root, under `base`. Every folder is in it. The root is removed when the process
///   exits.
/// - A folder can adopt a process, such as a test server whose data it holds. The process stops before the folder
///   is removed, and when the test process exits. The folder's record of the process is a file beside it.
/// - A test process that is killed removes nothing. So each test process first sweeps `base`: it stops the adopted
///   processes of every root whose test process is gone, and then removes that root.
public final class ScratchDirectory: Sendable {
  public let url: URL

  private let adopted = Mutex<[ProcessIdentity]>([])

  /// Makes a new, empty folder in this process's root. The label is the start of its name, for a person who looks
  /// in the root.
  public init(_ label: String = "scratch") throws {
    let root = try Self.root.get()
    url = root.appending(path: "\(label)-\(UUID().uuidString.prefix(8).lowercased())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
  }

  deinit {
    remove()
  }

  /// Makes the folder the keeper of a process: the process stops before the folder is removed, when the test
  /// process exits, and at a later sweep if the test process was killed.
  public func adopt(_ process: ProcessIdentity) throws {
    try adopted.withLock { adopted in
      try Self.record(adopted + [process], beside: url)
      adopted.append(process)
    }
    Self.running.withLock { _ = $0.insert(process) }
  }

  /// Stops the adopted processes, and removes the folder. The last holder's release does this too.
  public func remove() {
    let processes = adopted.withLock { adopted in
      defer { adopted = [] }
      return adopted
    }
    for process in processes {
      process.stop()
      Self.running.withLock { _ = $0.remove(process) }
    }
    try? FileManager.default.removeItem(at: Self.recordFile(beside: url))
    try? FileManager.default.removeItem(at: url)
  }
}

// MARK: - The roots

extension ScratchDirectory {
  /// The folder that holds one root for each test process, in the user's temporary folder.
  public static let base = FileManager.default.temporaryDirectory.appending(
    path: "wishbone-tests", directoryHint: .isDirectory)

  /// The adopted processes of this test process that still run.
  private static let running = Mutex<Set<ProcessIdentity>>([])

  /// This process's root. The first use sweeps `base`, makes the root, and arranges its removal at exit.
  private static let root: Result<URL, any Error> = Result {
    sweep(base)
    let root = try makeRoot(in: base, owner: .current)
    ownRoot.withLock { $0 = root }
    atexit { ScratchDirectory.cleanUpAtExit() }
    return root
  }

  /// The root to remove at exit.
  private static let ownRoot = Mutex<URL?>(nil)

  /// Stops the adopted processes that still run, and removes this process's root.
  private static func cleanUpAtExit() {
    for process in running.withLock({ $0 }) {
      process.stop()
    }
    if let root = ownRoot.withLock({ $0 }) {
      try? FileManager.default.removeItem(at: root)
    }
  }

  /// Makes the root of a test process in `base`, and returns it. The root's name holds its owner, so a sweep knows
  /// whether the owner is gone.
  public static func makeRoot(in base: URL, owner: ProcessIdentity) throws -> URL {
    let root = base.appending(path: "\(rootPrefix)\(owner.pid)-\(owner.started)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  /// Writes the record of the processes that the folder has adopted. The record is a file beside the folder.
  public static func record(_ processes: [ProcessIdentity], beside folder: URL) throws {
    try JSONEncoder().encode(processes).write(to: recordFile(beside: folder), options: .atomic)
  }

  /// Removes each root in `base` whose test process is gone. It first stops the processes that the root's folders
  /// adopted. Returns the roots that it removed.
  @discardableResult
  public static func sweep(_ base: URL) -> [URL] {
    let files = FileManager.default
    var swept: [URL] = []
    for root in (try? files.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
      guard let owner = owner(ofRootNamed: root.lastPathComponent), !owner.isRunning else { continue }
      for file in (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
      where file.pathExtension == recordExtension {
        guard let data = try? Data(contentsOf: file) else { continue }
        for process in (try? JSONDecoder().decode([ProcessIdentity].self, from: data)) ?? [] {
          process.stop()
        }
      }
      try? files.removeItem(at: root)
      swept.append(root)
    }
    return swept
  }

  private static let rootPrefix = "process-"
  private static let recordExtension = "processes"

  private static func recordFile(beside folder: URL) -> URL {
    folder.deletingLastPathComponent().appending(path: "\(folder.lastPathComponent).\(recordExtension)")
  }

  /// The owner in a root's name. Nil for a name that is not a root's, which a sweep leaves alone.
  private static func owner(ofRootNamed name: String) -> ProcessIdentity? {
    guard name.hasPrefix(rootPrefix) else { return nil }
    let parts = name.dropFirst(rootPrefix.count).split(separator: "-")
    guard parts.count == 2, let pid = Int32(parts[0]), let started = Int64(parts[1]) else { return nil }
    return ProcessIdentity(pid: pid, started: started)
  }
}
