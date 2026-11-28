import Synchronization
import WishboneSession

/// A notification center that doesn't answer the ask for provisional authorization until the test lets it. On a
/// simulator whose answer is not yet known, iOS took more than a minute to answer that ask.
///
/// Until it answers, the authorization is not determined. After, it is provisional. It schedules nothing, but counts
/// the asks and the replaces of the pending set.
final class HeldReminderCenter: ReminderCenter {
  private struct State {
    var isAsked = false
    var askCount = 0
    var replaceCount = 0
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

  /// How many times the session has asked for provisional authorization.
  var asks: Int { state.withLock { $0.askCount } }

  /// How many times the session has replaced the pending set: once at the end of each rebuild.
  var replaces: Int { state.withLock { $0.replaceCount } }

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
        state.askCount += 1
        defer { state.waitingForAsk = [] }
        if !state.isAnswered { state.asks.append(ask) }
        return (state.isAnswered, state.waitingForAsk)
      }
      for waiter in waiters { waiter.resume() }
      if isAnswered { ask.resume() }
    }
  }

  func requestFullAuthorization() async {}

  func replacePending(with requests: [ReminderRequest]) async {
    state.withLock { $0.replaceCount += 1 }
  }

  func removeAll() {}
}
