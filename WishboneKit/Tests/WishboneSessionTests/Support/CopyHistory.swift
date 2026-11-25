import Synchronization

@testable import WishboneSession

/// The copy of a session as each change left it, from the moment the history starts: every change, in the order of
/// the changes. What the session publishes can skip a change that a later one undid at once. The history doesn't, so
/// a test can say that a row never went away, not even for a moment.
@MainActor
final class CopyHistory {
  private let copies = Copies()
  private var observation: CopyObserver?

  private final class Copies: Sendable {
    let all = Mutex<[LocalDatabase.Snapshot]>([])
  }

  /// Starts the history of the session's copy now.
  init(of session: SessionModel) {
    observation = session.database.observeSnapshots(
      ofUser: session.session.userID,
      check: { [copies] _, whole in copies.all.withLock { $0.append(whole) } },
      onChange: { _ in })
  }

  /// Every copy since the history started, one for each change. The change that a session's call made has its copy
  /// here when the call returns, because the observation reads it inside the change's commit.
  private var all: [LocalDatabase.Snapshot] {
    copies.all.withLock { $0 }
  }

  /// How many changes the copy had since the history started.
  var count: Int { all.count }

  /// The gifts of the copy, after each change.
  var gifts: [[GiftRow]] { all.map(\.gifts) }

  /// The items of the copy, by their ID, after each change.
  var items: [[String: ItemRow]] {
    all.map { copy in
      Dictionary(copy.items.values.flatMap { $0 }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
  }

  /// The blocked stores of the copy, after each change.
  var blockedStores: [[BlockedStoreRow]] { all.map(\.blockedStores) }

  /// The session's user, as the copy held them after each change.
  var user: [UserRow?] { all.map(\.user) }

  /// Stops the history.
  func stop() {
    observation?.cancel()
    observation = nil
  }
}
