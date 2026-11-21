import Synchronization

/// A clock that moves only when a test moves it, for the timer that syncs every 60 seconds. A test sees whether the
/// timer waits on it, and moves it past the timer's deadline.
///
/// The hosted test bundle can't link `TestSupport`, whose `TestClock` this is a small copy of.
nonisolated final class ManualClock: Clock, Sendable {
  struct Instant: InstantProtocol {
    var offset: Duration

    func advanced(by duration: Duration) -> Instant {
      Instant(offset: offset + duration)
    }

    func duration(to other: Instant) -> Duration {
      other.offset - offset
    }

    static func < (earlier: Instant, later: Instant) -> Bool {
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
  }

  private let state = Mutex(State())

  var now: Instant {
    state.withLock { $0.now }
  }

  var minimumResolution: Duration {
    .zero
  }

  /// How many sleepers wait on the clock now.
  var sleeperCount: Int {
    state.withLock { $0.sleepers.count }
  }

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    let id = state.withLock { state in
      defer { state.nextID += 1 }
      return state.nextID
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let isDue = state.withLock { state in
          guard deadline > state.now else { return true }
          state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
          return false
        }
        if isDue {
          continuation.resume()
        } else if Task.isCancelled {
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
  func advance(by duration: Duration) {
    let due = state.withLock { state in
      state.now = state.now.advanced(by: duration)
      let due = state.sleepers.filter { $0.deadline <= state.now }
      state.sleepers.removeAll { $0.deadline <= state.now }
      return due
    }
    due.forEach { $0.continuation.resume() }
  }
}
