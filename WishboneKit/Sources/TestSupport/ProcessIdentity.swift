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
    guard let record = Self.record(of: pid) else { return nil }
    self.init(pid: pid, started: record.started)
  }

  /// Whether this run of the process is still going. A process that has ended, and that its parent has not
  /// collected yet, is not running.
  public var isRunning: Bool {
    guard let record = Self.record(of: pid) else { return false }
    return record.started == started && !record.hasEnded
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
    guard let record = Self.record(of: pid), record.started == started, record.hasEnded else { return }
    var status: Int32 = 0
    _ = waitpid(pid, &status, WNOHANG)
  }

  private func waitUntilGone(for limit: Duration) -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: limit)
    while isRunning {
      if clock.now >= deadline { return false }
      usleep(10_000)
    }
    return true
  }

  /// What the system knows about the process with the ID.
  private static func record(of pid: Int32) -> (started: Int64, hasEnded: Bool)? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let time = info.kp_proc.p_starttime
    let started = Int64(time.tv_sec) * 1_000_000 + Int64(time.tv_usec)
    return (started, Int32(info.kp_proc.p_stat) == SZOMB)
  }
}
