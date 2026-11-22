import WishboneAPI

/// Where the session asks iOS for its next background refresh. iOS decides when the refresh runs, if ever. See "When
/// the app syncs" in `docs/spec.md`.
///
/// Only the app gives the system's, which schedules through `BGTaskScheduler`. An extension gives none, so it never
/// schedules.
public protocol RefreshScheduler: Sendable {
  /// Asks for the next background refresh, no earlier than `delay` from now. It takes the place of the request that
  /// is pending, if there is one.
  func requestRefresh(after delay: Duration)

  /// Cancels the request that is pending, if there is one.
  func cancelRefresh()
}

/// No background refresh: the scheduler of the extensions, and of the tests that don't check it.
public struct NoRefreshScheduler: RefreshScheduler {
  public init() {}
  public func requestRefresh(after delay: Duration) {}
  public func cancelRefresh() {}
}

extension RefreshScheduler where Self == NoRefreshScheduler {
  /// No background refresh.
  public static var none: NoRefreshScheduler { NoRefreshScheduler() }
}

extension SyncOutcome {
  /// The outcome as the sync's breadcrumb names it.
  var end: SyncEnd {
    switch self {
    case .succeeded: .succeeded
    case .unreachable: .unreachable
    case .stopped: .stopped
    }
  }
}
