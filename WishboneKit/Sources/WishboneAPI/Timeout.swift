/// A piece of work passed its time limit.
///
/// Diagnostics: never. A timeout is one way that an instance is unreachable.
public struct TimedOut: Error, Sendable, Equatable {
  public init() {}
}

/// Runs the work, and throws `TimedOut` when it takes longer than the limit. Every timeout in the app goes
/// through this helper, on a clock that the caller injects, so a test never waits for the clock on the wall.
///
/// The work is cancelled when the limit passes. It must end when it is cancelled.
public func withTimeout<Result: Sendable>(
  _ limit: Duration,
  clock: any Clock<Duration>,
  _ work: @escaping @Sendable () async throws -> Result
) async throws -> Result {
  try await withThrowingTaskGroup(of: Result.self) { group in
    defer { group.cancelAll() }
    group.addTask { try await work() }
    group.addTask {
      try await clock.sleep(for: limit)
      throw TimedOut()
    }
    guard let first = try await group.next() else { throw CancellationError() }
    return first
  }
}
