import Synchronization
import WishboneSession

/// A notification center that keeps what the session asks of it, so a test can check the reminders that are
/// pending, when the session asks for authorization, and when it removes every reminder.
///
/// It stands for iOS: its authorization starts as the test gives it, and a request for provisional authorization
/// gets it, the first time, as iOS gives it while the user hasn't answered. A request for full authorization gets
/// the user's answer that the test gives, as the system alert does.
///
/// A test can hold the next call to `authorization()`, `requestFullAuthorization()` or `replacePending(with:)`, to see
/// what happens while the session waits on iOS.
final class RecordingReminderCenter: ReminderCenter {
  /// A call that a test can hold.
  enum Call: Equatable {
    case authorization

    /// Held before the user answers the system alert: the authorization is still provisional.
    case requestFullAuthorization
    case replacePending
  }

  private struct State {
    var authorization: ReminderAuthorization
    var answer: ReminderAuthorization
    var asks = 0
    var fullAsks = 0
    var pending: [ReminderRequest] = []
    var replaces = 0
    var removals = 0
    var hold: Call?
    var held: CheckedContinuation<Void, Never>?
    var waitingForHold: CheckedContinuation<Void, Never>?
  }

  private let state: Mutex<State>

  /// - Parameter answer: the user's answer to the system alert of full authorization: `.authorized` for Allow, and
  ///   `.denied` for Don't Allow.
  init(authorization: ReminderAuthorization = .provisional, answer: ReminderAuthorization = .authorized) {
    state = Mutex(State(authorization: authorization, answer: answer))
  }

  /// How many times the session asked for full authorization.
  var fullAsks: Int {
    state.withLock { $0.fullAsks }
  }

  /// Holds the next call, until `release()`.
  func hold(_ call: Call) {
    state.withLock { $0.hold = call }
  }

  /// Returns when a call is held.
  func waitUntilHeld() async {
    await withCheckedContinuation { continuation in
      let isHeld = state.withLock { state -> Bool in
        if state.held != nil { return true }
        state.waitingForHold = continuation
        return false
      }
      if isHeld { continuation.resume() }
    }
  }

  /// Lets the held call go on.
  func release() {
    let held = state.withLock { state -> CheckedContinuation<Void, Never>? in
      defer { state.held = nil }
      return state.held
    }
    held?.resume()
  }

  /// Waits here while the test holds the call.
  private func pause(at call: Call) async {
    let holds = state.withLock { state -> Bool in
      guard state.hold == call else { return false }
      state.hold = nil
      return true
    }
    guard holds else { return }
    await withCheckedContinuation { continuation in
      let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
        state.held = continuation
        defer { state.waitingForHold = nil }
        return state.waitingForHold
      }
      waiting?.resume()
    }
  }

  /// The reminders that are pending, in the order they were scheduled.
  var pending: [ReminderRequest] {
    state.withLock { $0.pending }
  }

  /// The identifiers of the pending reminders, in order.
  var identifiers: [String] {
    pending.map(\.identifier)
  }

  /// How many times the session asked for provisional authorization.
  var asks: Int {
    state.withLock { $0.asks }
  }

  /// How many times the session replaced the pending set.
  var replaces: Int {
    state.withLock { $0.replaces }
  }

  /// How many times the device removed every reminder.
  var removals: Int {
    state.withLock { $0.removals }
  }

  /// Schedules reminders as an earlier session left them, or sets what iOS lets the app do, as a test needs.
  func set(pending: [ReminderRequest]? = nil, authorization: ReminderAuthorization? = nil) {
    state.withLock { state in
      if let pending { state.pending = pending }
      if let authorization { state.authorization = authorization }
    }
  }

  func authorization() async -> ReminderAuthorization {
    await pause(at: .authorization)
    return state.withLock { $0.authorization }
  }

  func requestProvisionalAuthorization() async {
    state.withLock { state in
      state.asks += 1
      if state.authorization == .notDetermined { state.authorization = .provisional }
    }
  }

  func requestFullAuthorization() async {
    await pause(at: .requestFullAuthorization)
    state.withLock { state in
      state.fullAsks += 1
      // The system alert shows only while the user hasn't answered it: from provisional, or with no answer yet.
      if state.authorization == .provisional || state.authorization == .notDetermined {
        state.authorization = state.answer
      }
    }
  }

  func replacePending(with requests: [ReminderRequest]) async {
    await pause(at: .replacePending)
    state.withLock { state in
      state.pending = requests
      state.replaces += 1
    }
  }

  func removeAll() {
    state.withLock { state in
      state.pending = []
      state.removals += 1
    }
  }
}
