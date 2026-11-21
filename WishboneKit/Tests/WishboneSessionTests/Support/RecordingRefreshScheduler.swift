import Synchronization
import WishboneSession

/// A scheduler of background refresh that keeps what the session asks of it, in order, so a test can check when the
/// session asks iOS for a refresh, and when it cancels one.
final class RecordingRefreshScheduler: RefreshScheduler {
  /// What the session asked.
  enum Call: Equatable {
    /// A request for the next refresh, no earlier than the delay from now.
    case request(after: Duration)

    /// A cancel of the request that is pending.
    case cancel
  }

  private let record = Mutex<[Call]>([])

  /// Every call, in order.
  var calls: [Call] {
    record.withLock { $0 }
  }

  /// The requests only, in order.
  var requests: [Duration] {
    calls.compactMap { call in
      if case .request(let delay) = call { delay } else { nil }
    }
  }

  /// Whether a request is pending: the last call is a request.
  var isPending: Bool {
    if case .request = calls.last { true } else { false }
  }

  func requestRefresh(after delay: Duration) {
    record.withLock { $0.append(.request(after: delay)) }
  }

  func cancelRefresh() {
    record.withLock { $0.append(.cancel) }
  }
}
