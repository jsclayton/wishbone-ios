import Foundation
import WishboneAPI

// Leave, and Make {child} leave, on a list's page. See `docs/screens/list.md`, and in `docs/spec.md`: "Other writes
// that wait for the server", and "The rest, as the server has it".
//
// **Each waits for the server.** It is never an unsent change: the device can't know what the list shows after a
// leave until it syncs. With no connection, nothing changes and nothing waits to be sent.
//
// **The warning is the server's own rule.** It shows when the leaver's recipient row has `sees_list_after_leaving`,
// which only that user and their parents get. Nothing else in a confirmation depends on the list's gifts.

/// Someone who can leave a list from its page: the session's user, or one of their children.
public struct Leaver: Equatable, Sendable, Identifiable {
  /// The user who leaves.
  public let user: UserRow

  /// Whether the leaver is the session's user. Otherwise they are the user's child, and the button names them.
  public let isSessionUser: Bool

  /// Whether the leaver will still see the list after they leave it, and so see what's been claimed there. The
  /// confirmation then warns.
  public let seesListAfterLeaving: Bool

  public var id: String { user.id }
}

/// How Leave, or Make {child} leave, ended.
public enum LeaveOutcome: Sendable, Equatable {
  /// The server took the user off the list's recipients. The sync after it has ended, so the copy shows the list
  /// as the server now gives it, or not at all.
  case left

  /// The instance can't be reached. Nothing changes, and nothing waits to be sent.
  case unreachable

  /// The server refused, such as a 403 `last_recipient`.
  case refused(APIError.Refusal)

  /// A fault of the app, or a session that ended.
  case failed
}

extension SessionModel {
  /// Who can leave the list from its page: the session's user from the list's `can_leave`, and each child whose
  /// recipient row has `can_delete`, in the order they became recipients.
  func leavers(of list: ListRow) -> (own: Leaver?, children: [Leaver]) {
    let rows = recipients(ofList: list.id)
    let children = Set(user?.record?.childIDs ?? [])
    func leaver(_ row: RecipientRow, isSessionUser: Bool) -> Leaver? {
      guard let user = user(id: row.userID) else { return nil }
      return Leaver(
        user: user, isSessionUser: isSessionUser, seesListAfterLeaving: row.seesListAfterLeaving == .shown(true))
    }
    let own =
      list.canLeave ? rows.first { $0.userID == session.userID }.flatMap { leaver($0, isSessionUser: true) } : nil
    let ordered = rows.sorted { ($0.createdAt, $0.userID) < ($1.createdAt, $1.userID) }
    let others = ordered.filter { $0.canDelete && $0.userID != session.userID && children.contains($0.userID) }
    return (own, others.compactMap { leaver($0, isSessionUser: false) })
  }

  /// Leave, or Make {child} leave: takes the leaver off the list's recipients, with
  /// `DELETE /lists/{id}/recipients/{user_id}`. It waits for the server, and is never an unsent change. After the
  /// server answers, it syncs, and returns when that sync ends: only the server knows what the list shows now.
  ///
  /// A 404 counts as success: the leaver is not a recipient any more, or the list is gone. The sync shows which.
  ///
  /// Diagnostics: never here. A refusal is a 403, which the client doesn't capture.
  public func leave(list listID: String, as leaver: Leaver) async -> LeaveOutcome {
    guard !hasEnded else { return .failed }
    do {
      do {
        try await client.leave(list: listID, userID: leaver.user.id)
      } catch APIError.refused(let refusal) where refusal.status == 404 {
        // Left already, from another device, or the list went.
      }
      guard !hasEnded else { return .failed }
      await syncNow()
      return .left
    } catch {
      if let refusal = await outcome(of: error) { return .refused(refusal) }
      if case .unreachable = error { return .unreachable }
      return .failed
    }
  }
}
