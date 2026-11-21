import Darwin

/// One run of a process: its ID, and when it started.
///
/// The system gives an ID to another process after the first one ends. So a record of a process keeps both, and
/// nothing stops a process that only has the same ID.
public struct ProcessIdentity: Sendable, Hashable, Codable {
  public let pid: Int32

  /// When the process started, in microseconds since 1970.
  public let started: Int64

  /// The process that runs this code.
  public static let current: ProcessIdentity = {
    guard let identity = ProcessIdentity(pid: getpid()) else {
      fatalError("The system has no record of the process that asks.")
    }
    return identity
  }()

  public init(pid: Int32, started: Int64) {
    self.pid = pid
    self.started = started
  }

  /// The process that has the ID now. Nil when there is none.
  public init?(pid: Int32) {
    guard case .found(let record) = Self.look(for: pid) else { return nil }
    self.init(pid: pid, started: record.started)
  }

  /// Whether this run of the process is still going, for certain. A process that has ended, and that its parent
  /// has not collected yet, is not running.
  public var isRunning: Bool {
    guard case .found(let record) = Self.look(for: pid) else { return false }
    return record.started == started && !record.hasEnded
  }

  /// Whether this run of the process is over, for certain: the system has no process with the ID, or the ID now
  /// belongs to another run, or the process has ended. When the system can't say, the answer is false, as it is
  /// for `isRunning`. So nothing is removed, and nothing is stopped, on a guess.
  public var hasEnded: Bool {
    switch Self.look(for: pid) {
    case .found(let record): record.started != started || record.hasEnded
    case .none: true
    case .unknown: false
    }
  }

  /// Stops the process, and returns when it is gone. It asks first (`SIGTERM`), and kills the process
  /// (`SIGKILL`) when it is still running after `grace`.
  public func stop(grace: Duration = .seconds(5)) {
    if isRunning {
      kill(pid, SIGTERM)
      if !waitUntilGone(for: grace) {
        kill(pid, SIGKILL)
        _ = waitUntilGone(for: .seconds(5))
      }
    }
    collect()
  }

  /// Collects the process when it has ended and is a child of this one, so that the system forgets it.
  private func collect() {
    guard case .found(let record) = Self.look(for: pid), record.started == started, record.hasEnded else { return }
    var status: Int32 = 0
    _ = waitpid(pid, &status, WNOHANG)
  }

  private func waitUntilGone(for limit: Duration) -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: limit)
    while !hasEnded {
      if clock.now >= deadline { return false }
      usleep(10_000)
    }
    return true
  }

  /// What the system says about a process ID.
  private enum Look {
    /// A process has the ID.
    case found((started: Int64, hasEnded: Bool))
    /// No process has the ID.
    case none
    /// The system didn't say, for example to a process that may not read process information.
    case unknown
  }

  private static func look(for pid: Int32) -> Look {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0 else { return .unknown }
    // The call succeeds with nothing for an ID that no process has.
    guard size > 0 else { return .none }
    let time = info.kp_proc.p_starttime
    let started = Int64(time.tv_sec) * 1_000_000 + Int64(time.tv_usec)
    return .found((started, Int32(info.kp_proc.p_stat) == SZOMB))
  }
}
