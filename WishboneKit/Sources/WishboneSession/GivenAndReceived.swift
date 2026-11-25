import Foundation
import WishboneAPI

// Given and Received, the second and third parts of the Gifts tab, and a given gift's page. See
// `docs/screens/gifts.md`, `docs/screens/gift.md`, and "The For {name} part" in `docs/spec.md`.
//
// **Both are views of the same given gifts.** Given is the giver's, and Received the recipient's. The server sends a
// given gift to its giver, its recipients, and each recipient's parents, and to nobody else. A recipient's copy of a
// gift has no note and no bought mark, because the server doesn't send them. A parent's copy has the gifts given to
// their children, but never a gift that a child gave: the Gifts tab's Received is the user's own only. Nothing here
// goes to a system surface or into the shared container.

/// A group of Given or Received: the given gifts of one occasion, as it fell on one date. The session model builds
/// the groups from the copy: see `SessionModel.givenGroups` and `SessionModel.receivedGroups`.
public struct GiftHistoryGroup: Equatable, Sendable, Identifiable {
  /// The occasion's name and the date it fell on.
  public let id: String

  /// The occasion's name as it was at reveal. Nil when the session's user doesn't get it: the heading then has only
  /// the date.
  public let occasionName: String?

  /// The date the occasion fell on, as `YYYY-MM-DD`.
  public let occasionDate: String

  /// The gifts, the newest first.
  public let gifts: [GiftHistoryRow]
}

/// A given gift's row in Given or Received, with what its words need.
public struct GiftHistoryRow: Equatable, Sendable, Identifiable {
  /// The gift, with its title, image and price as they were at reveal.
  public let gift: GiftRow

  /// Who the gift went to, as the copy names them, at reveal. Nil when the session's user can't see them: a giver
  /// who couldn't see the list. A Given row then leaves out who it went to.
  public let recipients: [UserRow]?

  /// Who gave it: their name in the copy, or the name they had, once they are deleted.
  public let giverName: String

  public var id: String { gift.id }
}

/// What a given gift's page shows. The session model builds it from the copy: see `SessionModel.givenGiftPage(id:)`.
public struct GivenGiftPage: Equatable, Sendable {
  /// The gift, with its title, image and price as they were at reveal.
  public let gift: GiftRow

  /// Who the gift went to, at reveal. Nil when the session's user can't see them: the page then has no "For" line.
  public let recipients: [UserRow]?

  /// Who gave it: their name in the copy, or the name they had, once they are deleted.
  public let giverName: String

  /// Whether the session's user gave it. Only the giver sees the bought mark and the note, as they were.
  public let isGiver: Bool

  /// Whether the title pushes the item's page: the viewer can still see the item, so the copy holds it.
  public let linksItem: Bool

  /// Whether the list's name pushes the list's page: the viewer can see the list, and the copy holds it.
  public let linksList: Bool

  /// Whom I didn't get this speaks for, from the gift's `can_restore`. Nil when the page doesn't offer it, as for
  /// the gift's giver.
  public let restorer: Restorer?
}

extension SessionModel {
  /// Given: the gifts that the session's user gave, in groups by occasion, the newest first. The server's
  /// `?giver_id=me&state=given&sort=-given_at`.
  public var givenGroups: [GiftHistoryGroup] {
    historyGroups(given)
  }

  /// Received: the gifts given to the session's user, and not to their children, in groups by occasion, the newest
  /// first. The server's `?recipient_id=me&sort=-given_at`.
  public var receivedGroups: [GiftHistoryGroup] {
    historyGroups(received)
  }

  /// The gifts in groups by occasion: one group for each occasion's name and date, in the order of the gifts. The
  /// gifts are the newest first, so the groups are too.
  func historyGroups(_ gifts: [GiftRow]) -> [GiftHistoryGroup] {
    var order: [String] = []
    var byKey: [String: [GiftRow]] = [:]
    for gift in gifts {
      let key = "\(gift.occasionName ?? ""):\(gift.occasionDate)"
      if byKey[key] == nil { order.append(key) }
      byKey[key, default: []].append(gift)
    }
    return order.map { key in
      let gifts = byKey[key] ?? []
      return GiftHistoryGroup(
        id: key, occasionName: gifts[0].occasionName, occasionDate: gifts[0].occasionDate,
        gifts: gifts.map(historyRow))
    }
  }

  func historyRow(_ gift: GiftRow) -> GiftHistoryRow {
    GiftHistoryRow(gift: gift, recipients: recipients(of: gift), giverName: giverName(of: gift))
  }

  /// A given gift's page, from the copy. Nil when the gift is not in the copy, is not given, or the session's user
  /// is none of the users who see it: its giver, a recipient, or a recipient's parent. A gift that was restored
  /// leaves the copy of everyone but its giver at the next sync, and is open again in the giver's.
  public func givenGiftPage(id: String) -> GivenGiftPage? {
    guard let gift = gift(id: id), gift.state == .given else { return nil }
    let me = session.userID
    let children = Set(user?.record?.childIDs ?? [])
    let recipientIDs = gift.recipientIDs.value ?? []
    let isGiver = gift.giverID == me
    guard isGiver || recipientIDs.contains(me) || recipientIDs.contains(where: children.contains) else { return nil }
    let recipients = recipients(of: gift)
    return GivenGiftPage(
      gift: gift,
      recipients: recipients,
      giverName: giverName(of: gift),
      isGiver: isGiver,
      linksItem: itemPage(id: gift.itemID) != nil,
      linksList: recipients != nil && listPage(id: gift.listID) != nil,
      restorer: restorer(of: gift))
  }

  private func recipients(of gift: GiftRow) -> [UserRow]? {
    gift.recipientIDs.isHidden ? nil : (gift.recipientIDs.value ?? []).compactMap { user(id: $0) }
  }

  private func giverName(of gift: GiftRow) -> String {
    gift.giverID.flatMap { user(id: $0)?.name } ?? gift.giverName
  }
}
