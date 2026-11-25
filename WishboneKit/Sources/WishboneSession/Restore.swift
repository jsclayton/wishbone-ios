import Foundation
import WishboneAPI

// I didn't get this, on a given gift's page and a Received row. See `docs/screens/gift.md`, `docs/screens/gifts.md`,
// and "Other writes that wait for the server" in `docs/spec.md`.
//
// **It waits for the server.** It is never an unsent change: it hides the gift from the person who tapped it, so a
// later refusal would have nothing to roll back to. With no connection, nothing changes and nothing waits to be sent.
//
// **Nothing here says anything about the giver.** The server opens the gift again for an active giver, and deletes it
// for one who is deactivated or deleted. The recipient's copy is the same either way: the gift leaves it.

/// Whom I didn't get this speaks for, on a given gift's page.
public enum Restorer: Equatable, Sendable {
  /// The session's user received the gift.
  case sessionUser

  /// The session's user is the parent of the child who received it. The confirmation names the child.
  case child(UserRow)
}

/// How I didn't get this ended.
public enum RestoreOutcome: Sendable, Equatable {
  /// The server took the gift back to its giver, or it was gone already (a 404). The gift has left the copy.
  case restored

  /// The copy doesn't offer it: the gift is not given, is not in the copy, or has no `can_restore`. Nothing was sent.
  case notOffered

  /// The instance can't be reached. Nothing changes, and nothing waits to be sent.
  case unreachable

  /// The server refused, such as a 403 `user_deactivated`.
  case refused(APIError.Refusal)

  /// A fault of the app, or a session that ended.
  case failed
}

extension SessionModel {
  /// Whom I didn't get this speaks for on the gift's page, from its `can_restore`: the session's user when they
  /// received it, or else the first of their children who did. Nil when the page doesn't offer it.
  func restorer(of gift: GiftRow) -> Restorer? {
    guard gift.state == .given, gift.canRestore else { return nil }
    let recipientIDs = gift.recipientIDs.value ?? []
    if recipientIDs.contains(session.userID) { return .sessionUser }
    let children = Set(user?.record?.childIDs ?? [])
    guard let child = recipientIDs.first(where: children.contains).flatMap({ user(id: $0) }) else {
      return .sessionUser
    }
    return .child(child)
  }

  /// I didn't get this: says that the given gift didn't arrive, with `POST /gifts/{id}/restore`. It waits for the
  /// server, and is never an unsent change. After the server answers, the gift leaves the copy in every window, and
  /// a pull that asked before the answer doesn't bring it back.
  ///
  /// A 404 counts as success: the gift was restored already, from another device, or the giver unclaimed it.
  ///
  /// Diagnostics: never here. A refusal is a 403 or a 404, which the client doesn't capture.
  public func restore(gift id: String) async -> RestoreOutcome {
    guard !hasEnded, let gift = gift(id: id), gift.state == .given, gift.canRestore else { return .notOffered }
    do {
      do {
        try await client.restoreGift(id)
      } catch APIError.refused(let refusal) where refusal.status == 404 {
        // Restored already, from another device.
      }
      guard !hasEnded else { return .failed }
      try await database.removeRestoredGift(id)
      // A sync that runs now may have asked before the restore. Its pull doesn't put the gift back, and one more
      // sync asks after it.
      syncAgainIfSyncing()
      await publishNow()
      return .restored
    } catch let error as APIError {
      if let refusal = await outcome(of: error) { return .refused(refusal) }
      if case .unreachable = error { return .unreachable }
      return .failed
    } catch is CancellationError {
      return .failed
    } catch {
      Log.fault(.session, "The copy can't drop the restored gift.", detail: "\(error)")
      return .failed
    }
  }
}
