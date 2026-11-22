import Synchronization
import WishboneSession

/// A notification center that keeps what the session asks of it, so a test can check the reminders that are
/// pending, when the session asks for authorization, and when it removes every reminder.
///
/// It stands for iOS: its authorization starts as the test gives it, and a request for provisional authorization
/// gets it, the first time, as iOS gives it while the user hasn't answered.
final class RecordingReminderCenter: ReminderCenter {
  private struct State {
    var authorization: ReminderAuthorization
    var asks = 0
    var pending: [ReminderRequest] = []
    var replaces = 0
    var removals = 0
  }

  private let state: Mutex<State>

  init(authorization: ReminderAuthorization = .provisional) {
    state = Mutex(State(authorization: authorization))
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
    state.withLock { $0.authorization }
  }

  func requestProvisionalAuthorization() async {
    state.withLock { state in
      state.asks += 1
      if state.authorization == .notDetermined { state.authorization = .provisional }
    }
  }

  func replacePending(with requests: [ReminderRequest]) async {
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
