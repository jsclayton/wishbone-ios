import Foundation
import WishboneAPI

// A gift's occasion: the occasions that a giver can pick for a gift, the pick, and Get another for a different
// occasion. See "Pick the occasion" and "Get another for a different occasion" in `docs/screens/gift.md`, "Unsent
// changes" and "Claims are online only" in `docs/spec.md`, and "Occasions for a gift" in the server's spec.
//
// - The occasions come from the copy, by the server's rule. No page fetches anything of its own.
// - A pick is an unsent change: it shows at once, in every window, with the reveal that follows it. When the giver
//   has another open gift on the item for that occasion, the two merge, as the server merges them.
// - Get another is a claim, and never an unsent change. It waits for the server's answer. With no connection,
//   nothing is claimed and nothing waits to be sent.
//
// **Only its giver sees an open gift,** and nothing here says who else claimed the item. Nothing here goes to a system
// surface or into the shared container.

/// How Get another for a different occasion ended. See "Get another for a different occasion" in
/// `docs/screens/gift.md`.
///
/// **No outcome says who else claimed.**
public enum GetAnotherOutcome: Sendable, Equatable {
  /// The server granted the claim. The copy holds the new gift: its page is pushed.
  case claimed(giftID: String)

  /// Get another isn't offered for the gift: the item can't be claimed, or no occasion that the giver can pick is
  /// free. Nothing was sent.
  case notOffered

  /// The claim made no gift. Its words are those of I'll get this.
  case notClaimed(ClaimOutcome)
}

extension SessionModel {
  /// The occasions that the session's user can pick for a gift on the list, soonest first: the upcoming occasions of
  /// the list's recipients, other than the user, whom the user can see. The server's `GET /occasions?list_id=`, from
  /// the copy.
  ///
  /// A recipient counts when the copy holds them in full, which is the users that `GET /users` gives, and they are
  /// not deactivated: for gifts, no giver sees a deactivated recipient. An occasion counts when the copy holds it,
  /// which is the occasions that the user can see, when it has a next date, and when it applies to such a recipient:
  /// a birthday or a custom occasion to its user, and a shared occasion to the users of its membership. The order
  /// is the server's: the next date, then the name in lower case, then the ID.
  ///
  /// Empty for a list that is not in the copy, and when the user can see none of the other recipients.
  ///
  /// Two places where this rule can differ from the server's, though neither does today:
  /// - **A kind that the app doesn't know** counts as a shared occasion does, by its membership. The server
  ///   matches an occasion of any kind by its user, so a later kind that has a user and no membership would be
  ///   missing here.
  /// - **Names on the same date** are compared as Swift compares lower-case strings, where the server compares the
  ///   bytes of Go's lower case. The two agree for ASCII, and can order some other names differently.
  public func pickableOccasions(onList id: String) -> [OccasionRow] {
    let givable = givableRecipients(onList: id)
    guard !givable.isEmpty else { return [] }
    let picked = occasions.filter { occasion in
      guard occasion.nextDate != nil else { return false }
      switch occasion.kind {
      case .birthday, .custom:
        return occasion.userID.map(givable.contains) ?? false
      case .shared, .unknown:
        return occasion.isEveryone == true
          || (members(.usersOfOccasion, of: occasion.id) ?? []).contains(where: givable.contains)
      }
    }
    return picked.sorted { first, second in
      let keys = (first.nextDate ?? "", second.nextDate ?? "")
      if keys.0 != keys.1 { return keys.0 < keys.1 }
      let names = (first.name.lowercased(), second.name.lowercased())
      if names.0 != names.1 { return names.0 < names.1 }
      return (Int(first.id) ?? 0, first.id) < (Int(second.id) ?? 0, second.id)
    }
  }

  /// Whether the session's user can pick the gift's occasion: they can edit it, and can see another of its list's
  /// recipients. When they can see none, the server picks the occasion (`occasion_locked`), and the row is not a
  /// button.
  public func canPickOccasion(ofGift id: String) -> Bool {
    guard !hasEnded, let gift = gift(id: id), gift.state == .open, gift.canEdit else { return false }
    return !givableRecipients(onList: gift.listID).isEmpty
  }

  /// The occasion that Get another for a different occasion claims for: the soonest occasion that the giver can
  /// pick for a gift on the item's list, for which they have no open gift on the item. Nil when Get another isn't
  /// offered: the copy doesn't hold the item, its `can_claim` is false, the giver is a recipient of its list as the
  /// copy shows it (an accept that waits), or no such occasion is left.
  public func anotherOccasion(forGift id: String) -> OccasionRow? {
    guard !hasEnded, let gift = gift(id: id), gift.state == .open, gift.giverID == session.userID,
      let item = item(id: gift.itemID), item.canClaim, !isRecipient(ofList: item.listID)
    else { return nil }
    let taken = Set(giving.filter { $0.itemID == item.id }.compactMap(\.occasion?.id))
    return pickableOccasions(onList: item.listID).first { !taken.contains($0.id) }
  }

  /// Pick the occasion: moves the gift to the occasion, as an unsent change. It shows at once, in every window, with
  /// the reveal that follows it, and a sync sends it.
  ///
  /// When the giver has another open gift on the item for that occasion, the two merge, as the server merges them:
  /// the other gift stays, and takes this one in. It gives back the ID of the gift that holds the pick now: the other
  /// gift's after a merge, so a page that showed this gift shows that one. Nil when it did nothing: for a gift that
  /// the copy doesn't hold, that the giver can't pick for, for an occasion that isn't one they can pick, or for the
  /// gift's own occasion.
  @discardableResult
  public func pickOccasion(_ occasionID: String, forGift id: String) async -> String? {
    guard canPickOccasion(ofGift: id), let gift = gift(id: id), gift.occasion?.id != occasionID,
      let occasion = pickableOccasions(onList: gift.listID).first(where: { $0.id == occasionID }),
      let date = occasion.nextDate
    else { return nil }
    let holder = self.gift(holdingPick: occasionID, of: id)
    let pick = PickedOccasion(id: occasion.id, kind: occasion.kind, name: occasion.name, date: date)
    await record(.setOccasion(giftID: id, occasion: pick), title: gift.title)
    return holder
  }

  /// The gift that would hold a pick of the occasion for the gift: the giver's other open gift on the item for that
  /// occasion, which takes this one in, or this one. So a page can follow the pick before it shows.
  public func gift(holdingPick occasionID: String, of id: String) -> String {
    guard let gift = gift(id: id) else { return id }
    return giving.first { $0.id != id && $0.itemID == gift.itemID && $0.occasion?.id == occasionID }?.id ?? id
  }

  /// Get another for a different occasion: claims one of the gift's item for the soonest occasion that the giver
  /// can pick and has no gift for, with `POST /items/{id}/gifts`. It waits for the server's answer, and is never an
  /// unsent change. See "Claims are online only" in `docs/spec.md`.
  ///
  /// On success, the new gift and the item go into the copy, and the session model publishes them before it
  /// returns, so the new gift's page can be pushed at once.
  ///
  /// Diagnostics: never here. A refused claim is a 403 or a 409, which the client doesn't capture, and a 422 of a
  /// write the client captures itself.
  public func getAnother(forGift id: String) async -> GetAnotherOutcome {
    guard let gift = gift(id: id), let occasion = anotherOccasion(forGift: id) else { return .notOffered }
    do {
      let gifts = try await claimOne(of: gift.itemID, for: occasion.id)
      guard let made = gifts.first(where: { $0.resource.occasion?.id == occasion.id }) ?? gifts.first else {
        return .notClaimed(.failed)
      }
      return .claimed(giftID: made.resource.id)
    } catch {
      return .notClaimed(await claimOutcome(of: error))
    }
  }

  /// The recipients of the list whom the session's user can give to: the ones the copy holds in full, other than
  /// the user, who are not deactivated. Empty for a list that is not in the copy.
  private func givableRecipients(onList id: String) -> Set<String> {
    Set(
      recipients(ofList: id).map(\.userID).filter { userID in
        guard userID != session.userID, let record = user(id: userID)?.record else { return false }
        return record.deactivatedAt.value == nil
      })
  }
}
