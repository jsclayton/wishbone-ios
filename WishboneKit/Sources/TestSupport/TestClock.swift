import Synchronization

/// A clock that moves only when a test moves it. Code that takes an injected clock sleeps on it, and the test
/// advances it past the deadline, so no test waits for the clock on the wall.
///
/// A test first waits for the sleeper (`waitForSleepers`), and then advances the clock. A sleep that starts after
/// the advance would count from the new time, and never wake.
public final class TestClock: Clock, Sendable {
  public struct Instant: InstantProtocol {
    public var offset: Duration

    public func advanced(by duration: Duration) -> Instant {
      Instant(offset: offset + duration)
    }

    public func duration(to other: Instant) -> Duration {
      other.offset - offset
    }

    public static func < (earlier: Instant, later: Instant) -> Bool {
      earlier.offset < later.offset
    }
  }

  private struct Sleeper {
    let id: Int
    let deadline: Instant
    let continuation: CheckedContinuation<Void, any Error>
  }

  private struct State {
    var now = Instant(offset: .zero)
    var nextID = 0
    var sleepers: [Sleeper] = []
    var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  }

  private let state = Mutex(State())

  public init() {}

  public var now: Instant {
    state.withLock { $0.now }
  }

  public var minimumResolution: Duration {
    .zero
  }

  public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    let id = state.withLock { state in
      defer { state.nextID += 1 }
      return state.nextID
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let (isDue, watchers) = state.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
          guard deadline > state.now else { return (true, []) }
          state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
          let ready = state.watchers.filter { $0.count <= state.sleepers.count }.map(\.continuation)
          state.watchers.removeAll { $0.count <= state.sleepers.count }
          return (false, ready)
        }
        watchers.forEach { $0.resume() }
        if isDue {
          continuation.resume()
        } else if Task.isCancelled {
          // The task was cancelled before the sleeper was in place, so the handler below found nothing to wake.
          cancel(id)
        }
      }
    } onCancel: {
      cancel(id)
    }
  }

  private func cancel(_ id: Int) {
    let sleeper = state.withLock { state in
      state.sleepers.firstIndex { $0.id == id }.map { state.sleepers.remove(at: $0) }
    }
    sleeper?.continuation.resume(throwing: CancellationError())
  }

  /// Moves the clock forward, and wakes each sleeper whose deadline has come.
  public func advance(by duration: Duration) {
    let due = state.withLock { state in
      state.now = state.now.advanced(by: duration)
      let due = state.sleepers.filter { $0.deadline <= state.now }
      state.sleepers.removeAll { $0.deadline <= state.now }
      return due
    }
    due.forEach { $0.continuation.resume() }
  }

  /// How many sleepers wait on the clock now. A test reads it once the code under test can have started no sleep
  /// that it still waits to place, for example after that code's next action has ended.
  public var sleeperCount: Int {
    state.withLock { $0.sleepers.count }
  }

  /// Returns when at least `count` sleepers wait on the clock.
  public func waitForSleepers(_ count: Int = 1) async {
    await withCheckedContinuation { continuation in
      let isReady = state.withLock { state in
        if state.sleepers.count >= count { return true }
        state.watchers.append((count, continuation))
        return false
      }
      if isReady { continuation.resume() }
    }
  }
}
