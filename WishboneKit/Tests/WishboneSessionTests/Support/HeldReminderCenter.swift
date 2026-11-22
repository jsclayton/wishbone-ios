import Synchronization
import WishboneSession

/// A notification center that doesn't answer the ask for provisional authorization until the test lets it. On a
/// simulator whose answer is not yet known, iOS took more than a minute to answer that ask.
///
/// Until it answers, the authorization is not determined. After, it is provisional. It schedules nothing.
final class HeldReminderCenter: ReminderCenter {
  private struct State {
    var isAsked = false
    var isAnswered = false
    var waitingForAsk: [CheckedContinuation<Void, Never>] = []
    var asks: [CheckedContinuation<Void, Never>] = []
  }

  private let state = Mutex(State())

  /// Returns when the session has asked.
  func waitUntilAsked() async {
    await withCheckedContinuation { waiter in
      let isAsked = state.withLock { state in
        if !state.isAsked { state.waitingForAsk.append(waiter) }
        return state.isAsked
      }
      if isAsked { waiter.resume() }
    }
  }

  /// Answers the ask, and every later one at once.
  func answer() {
    let asks = state.withLock { state in
      state.isAnswered = true
      defer { state.asks = [] }
      return state.asks
    }
    for ask in asks { ask.resume() }
  }

  func authorization() async -> ReminderAuthorization {
    state.withLock { $0.isAnswered } ? .provisional : .notDetermined
  }

  func requestProvisionalAuthorization() async {
    await withCheckedContinuation { ask in
      let (isAnswered, waiters) = state.withLock { state in
        state.isAsked = true
        defer { state.waitingForAsk = [] }
        if !state.isAnswered { state.asks.append(ask) }
        return (state.isAnswered, state.waitingForAsk)
      }
      for waiter in waiters { waiter.resume() }
      if isAnswered { ask.resume() }
    }
  }

  func replacePending(with requests: [ReminderRequest]) async {}

  func removeAll() {}
}
