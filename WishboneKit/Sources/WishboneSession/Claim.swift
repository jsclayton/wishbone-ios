import Foundation
import WishboneAPI

/// How I'll get this ended. See "States" in `docs/screens/item.md`, and "Claims are online only" in
/// `docs/spec.md`.
///
/// **No outcome says who else claimed.** A claim that came after the last one is `someoneElseGotIt`, and nothing
/// more.
public enum ClaimOutcome: Sendable, Equatable {
  /// The server granted the claim, or had it already (409 `already_claimed`). The copy holds the gift, and the
  /// item's new numbers when the instance gave them.
  case claimed

  /// Someone else got the last one first (409 `item_fully_claimed`). Nothing was claimed, and the copy is as it
  /// was: the item leaves the giver's lists at the next sync.
  case someoneElseGotIt

  /// The instance can't be reached. Nothing was claimed, and nothing waits to be sent.
  case unreachable

  /// The server refused the claim for another reason, such as `recipient_cannot_claim` or `user_deactivated`.
  case refused(APIError.Refusal)

  /// A fault of the app, such as an answer that it can't read, or a session that ended.
  case failed
}

extension SessionModel {
  /// I'll get this: claims one of the item, for the soonest occasion that the giver may pick, with
  /// `POST /items/{id}/gifts`. It waits for the server's answer, and is never an unsent change: a claim made offline
  /// and refused later is a double gift. See "Claims are online only" in `docs/spec.md`.
  ///
  /// On success, the gift and the item as the server gives it now go into the copy in one change, and the session
  /// model publishes them before it returns, so every window shows them at once. A claim whose answer was lost,
  /// tapped again, gets 409 `already_claimed`: that is success, and the copy takes the giver's gifts on the item.
  ///
  /// Diagnostics: never here. A refused claim is a 403 or a 409, which the client doesn't capture.
  public func claim(item id: String) async -> ClaimOutcome {
    guard !hasEnded else { return .failed }
    do {
      _ = try await claimOne(of: id, for: nil)
      return .claimed
    } catch {
      return await claimOutcome(of: error)
    }
  }

  /// Claims one of the item, for the occasion or for the server's own pick, and saves the giver's gifts that the
  /// claim made or found into the copy, with the item's new numbers, and publishes them. Gives back the gifts.
  func claimOne(of id: String, for occasionID: String?) async throws -> [Versioned<Gift>] {
    let gifts: [Versioned<Gift>]
    do {
      gifts = [try await client.claim(id, occasionID: occasionID)]
    } catch APIError.refused(let refusal) where refusal.code == .alreadyClaimed {
      // The server has the gift: the answer to an earlier tap was lost. The gifts on the item that the session's
      // user can see are their own.
      let onItem = try? await client.gifts(ofItem: id)
      gifts = (onItem?.rows ?? []).filter { $0.resource.giver?.id == session.userID && $0.resource.state == .open }
    }
    // The item's new numbers. Without them, the gift is saved alone, and the next sync brings the item.
    let item = try? await client.item(id)
    guard !hasEnded else { throw CancellationError() }
    try await database.saveClaim(gifts, item: item)
    // A sync that runs now may have asked before the claim. Its pull keeps the gift, and one more sync asks after it.
    syncAgainIfSyncing()
    await publishNow()
    return gifts
  }

  /// How a claim that threw ended.
  func claimOutcome(of error: any Error) async -> ClaimOutcome {
    switch error {
    case APIError.refused(let refusal) where refusal.code == .itemFullyClaimed:
      return .someoneElseGotIt
    case let error as APIError:
      if let refusal = await outcome(of: error) { return .refused(refusal) }
      if case .unreachable = error { return .unreachable }
      return .failed
    case is CancellationError:
      return .failed
    default:
      Log.fault(.session, "The copy can't take the claim.", detail: "\(error)")
      return .failed
    }
  }
}
