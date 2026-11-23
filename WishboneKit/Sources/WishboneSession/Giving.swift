import Foundation
import WishboneAPI

// Giving, the first part of the Gifts tab: the session's user's open gifts, in groups by list and occasion, and the
// tab's badge. See `docs/screens/gifts.md`, and "Home" in `docs/spec.md` for the badge.
//
// **Only the giver sees any of it.** It is built from the giver's own open gifts, which the server never sends to
// their recipients. Nothing here goes to a system surface or into the shared container.

/// A group of Giving: the giver's open gifts of one list for one occasion. The session model builds the groups from
/// the copy: see `SessionModel.givingGroups`.
public struct GivingGroup: Equatable, Sendable, Identifiable {
  /// The list, the occasion, and the date that the occasion fell on, as the web's Giving groups them.
  public let id: String

  /// Who the gifts are for, as the copy names them, in the server's order. Nil when the giver can't see the list:
  /// the heading then has only the occasion, or the reveal date.
  public let recipients: [UserRow]?

  /// The occasion that the heading names, or only the reveal date when the giver can't see the occasion.
  public let occasion: ItemPage.ClaimLine.Occasion

  /// The gifts, the soonest reveal first.
  public let gifts: [GivingGift]

  /// Whether a gift of the group needs its giver's attention. Such a group goes first.
  public var needsAttention: Bool {
    gifts.contains(where: \.needsAttention)
  }
}

/// A gift's row in Giving: the gift, and its flags with what their words need.
public struct GivingGift: Equatable, Sendable, Identifiable {
  public let gift: GiftRow

  /// The flags that the app has words for, in the server's order. A code that the app doesn't know is left out.
  public let flags: [Flag]

  public var id: String { gift.id }

  /// The server's `needs_attention`, as it sent it.
  public var needsAttention: Bool { gift.needsAttention.value == true }

  /// A flag of the gift, with what its words name. See "Words" in `docs/screens/gifts.md`.
  public enum Flag: Equatable, Sendable {
    /// "The item changed".
    case changed

    /// "Removed from the list".
    case removed

    /// "Moved to {list}". Nil when the giver can't see the new list: "Moved to another list".
    case moved(toList: String?)

    /// "Now for {occasion}": the gift's occasion now. Nil when the giver can't see it.
    case occasionMoved(to: String?)

    /// "No longer shared with you".
    case noLongerShared

    /// "{name} says they didn't get this". Nil when the giver can't see who: "Marked as not received".
    case restored(by: String?)

    /// "Now for {names}": the recipients now. Nil or empty when the giver can't see them: "The recipients changed".
    case recipientsChanged(to: [String]?)
  }
}

extension SessionModel {
  /// Giving, in groups by list and occasion. A group with a gift that needs attention goes first. Then the groups
  /// are in order of reveal, the soonest first. Each part keeps that order.
  public var givingGroups: [GivingGroup] {
    var order: [String] = []
    var byKey: [String: [GiftRow]] = [:]
    for gift in giving {
      let key = "\(gift.listID):\(gift.occasion?.id ?? "hidden"):\(gift.occasionDate)"
      if byKey[key] == nil { order.append(key) }
      byKey[key, default: []].append(gift)
    }
    let groups = order.map { key in
      let gifts = byKey[key] ?? []
      let first = gifts[0]
      return GivingGroup(
        id: key,
        recipients: first.recipientIDs.isHidden ? nil : (first.recipientIDs.value ?? []).compactMap { user(id: $0) },
        occasion: ItemPage.ClaimLine(first).occasion,
        gifts: gifts.map(givingGift))
    }
    return groups.filter(\.needsAttention) + groups.filter { !$0.needsAttention }
  }

  /// The Gifts tab's badge: how many of the session's user's open gifts need their attention, as the server says
  /// with `needs_attention`. Nil at zero, so the tab has no badge. It is the server's
  /// `GET /gifts?giver_id=me&state=open&needs_attention=true`.
  public var giftsBadge: Int? {
    let count = giving.count { $0.needsAttention.value == true }
    return count == 0 ? nil : count
  }

  private func givingGift(_ gift: GiftRow) -> GivingGift {
    let flags = (gift.flags.value ?? []).compactMap { flag -> GivingGift.Flag? in
      switch flag {
      case .changed: .changed
      case .removed: .removed
      case .moved(let list): .moved(toList: list?.name)
      case .occasionMoved: .occasionMoved(to: gift.occasion == nil ? nil : gift.occasionName)
      case .noLongerShared: .noLongerShared
      case .restored(let id): .restored(by: id.flatMap { user(id: $0)?.name })
      case .recipientsChanged(_, let new): .recipientsChanged(to: new?.compactMap { user(id: $0)?.name })
      case .unknown: nil
      }
    }
    return GivingGift(gift: gift, flags: flags)
  }
}
