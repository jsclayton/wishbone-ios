import Foundation
import WishboneAPI

// An item's page, from the copy: the images, the title and the price, the list and its recipients, how many are
// still wanted for a giver or wanted for an editor, the notes, the store links, and "Added by {name}". See
// `docs/screens/item.md`, and "How each thing is reached" in `docs/spec.md`.
//
// **Claim state shows only as the server sends it.** A giver gets how many are still wanted, and nothing here says
// who else claimed. A recipient gets none of it. Copy link carries only the first store link.

/// What an item's page shows. The session model builds it from the copy: see `SessionModel.itemPage(id:)`.
public struct ItemPage: Equatable, Sendable {
  public let item: ItemRow

  /// The item's list. The item's address has no list, so after a move this is the new one.
  public let list: ListRow

  /// The list's recipients, in the order they became recipients. A name links as on the list's page.
  public let recipients: [ListPage.Recipient]

  /// The images, the primary image first, then the rest in the order they were added. Empty when there is none.
  public let images: [ImageSummary]

  /// How many are still wanted, for a giver, as the server sends it. Nil for a recipient, whose copy has it
  /// hidden.
  public let stillWanted: StillWanted?

  /// How many are wanted, for a user who can edit the item. Nil for anyone else.
  public let wanted: Wanted?

  /// The store links, in the order that the server gives the session's user: the lowest price first for a giver,
  /// the order added for a user who can edit.
  public let storeLinks: [StoreLinkRow]

  /// The user for "Added by {name}". Nil when it doesn't show: that user is the list's only recipient, or was
  /// deleted.
  public let addedBy: UserRow?

  /// Whether the page offers I'll get this: the server's `can_claim`, while the giver has no open gift on the item.
  /// Never for a recipient, whose `can_claim` is always false.
  public let offersClaim: Bool

  /// One line for each of the session's user's own open gifts on the item, the soonest reveal first: "You claimed 1
  /// for Christmas". They take the place of I'll get this. Empty for anyone but a giver with a gift on it.
  public let claims: [ClaimLine]

  /// A line of the giver's own gift on the item. It names the gift's occasion, or only its reveal date when the
  /// giver can't see the occasion.
  public struct ClaimLine: Equatable, Sendable, Identifiable {
    public let id: String
    public let quantity: Int
    public let occasion: Occasion

    public enum Occasion: Equatable, Sendable {
      /// "You claimed 1 for Christmas".
      case named(String)
      /// "You claimed 1 · hidden until Mar 4": the giver can't see the gift's occasion.
      case hiddenUntil(Date)
    }

    public init(id: String, quantity: Int, occasion: Occasion) {
      self.id = id
      self.quantity = quantity
      self.occasion = occasion
    }

    public init(_ gift: GiftRow) {
      id = gift.id
      quantity = gift.quantity
      if gift.occasion != nil, let name = gift.occasionName {
        occasion = .named(name)
      } else {
        occasion = .hiddenUntil(gift.revealAt)
      }
    }
  }

  /// Whether I'll get this is offered for the item: from `can_claim`, while `my_claimed_quantity` is 0 and the copy
  /// holds no open gift of the giver's on it. The server allows one gift for each item and occasion, so a giver
  /// with a gift raises its quantity on the gift's page instead.
  public static func offersClaim(_ item: ItemRow, openGifts: [GiftRow]) -> Bool {
    item.canClaim && (item.myClaimedQuantity.value ?? 0) == 0 && !openGifts.contains { $0.itemID == item.id }
  }

  /// How many are still wanted, for a giver: "{n} of {m} still wanted", or "Always wanted".
  public enum StillWanted: Equatable, Sendable {
    case count(Int, of: Int)
    case always
  }

  /// How many are wanted, for a user who can edit: "Wants {n}", or "Always wanted".
  public enum Wanted: Equatable, Sendable {
    case count(Int)
    case always
  }

  /// What Copy link copies: the first store link, in the session's user's order, and nothing else. Nil when the
  /// item has no store link, and then Copy link is not offered.
  public var copyLink: URL? {
    Self.copyLink(of: storeLinks)
  }

  /// What Copy link copies from an item's store links, on its page and in its row's context menu: the first, in
  /// the session's user's order. Nil when there is none.
  static func copyLink(of storeLinks: [StoreLinkRow]) -> URL? {
    ordered(storeLinks).first.flatMap { URL(string: $0.url) }
  }

  /// The store links in the session's user's order, as the server gives their positions.
  static func ordered(_ storeLinks: [StoreLinkRow]) -> [StoreLinkRow] {
    storeLinks.sorted { $0.position < $1.position }
  }

  /// The user that "Added by {name}" names, by the server spec's rule. Nil when it doesn't show: the user was
  /// deleted, so the item has none, or the user is the list's only recipient.
  public static func addedByID(_ addedByID: String?, recipientIDs: [String]) -> String? {
    guard let addedByID, recipientIDs != [addedByID] else { return nil }
    return addedByID
  }
}

extension SessionModel {
  /// What Copy link copies for an item's row: the item's first store link, in the session's user's order, as on
  /// its page. Nil when it has none.
  public func copyLink(ofItem id: String) -> URL? {
    ItemPage.copyLink(of: storeLinks(ofItem: id))
  }

  /// The item's page, from the copy. Nil when the page is the "not found" page: the item is not in the copy, which
  /// is the same for an item that was deleted and one that the session's user can no longer see.
  ///
  /// A recipient of the list gets no claim state, as on the list's page: no still wanted, no I'll get this, and no
  /// claim lines. The server already hides them from a recipient. Until the next pull after an accept, though, the
  /// copy's item rows are still the giver's rows, while the list (with the journal applied) has the user as a
  /// recipient.
  ///
  /// A page opened by a stand-in ID shows the item still when the server's ID takes its place.
  public func itemPage(id: String) -> ItemPage? {
    guard let item = item(id: id), let list = list(id: item.listID) else { return nil }
    let id = item.id
    let isRecipient = list.recipientIDs.contains(session.userID)

    let stillWanted: ItemPage.StillWanted? =
      switch isRecipient ? .hidden : item.stillWanted {
      case .hidden: nil
      case .shown(let count?): .count(count, of: item.quantity)
      case .shown(nil): .always
      }
    let wanted: ItemPage.Wanted? = item.canEdit ? (item.isUnlimited ? .always : .count(item.quantity)) : nil

    let addedBy = ItemPage.addedByID(item.addedByID, recipientIDs: list.recipientIDs).flatMap { user(id: $0) }

    let primary = item.primaryImage ?? item.images.first
    let images = (primary.map { [$0] } ?? []) + item.images.filter { $0.id != primary?.id }

    return ItemPage(
      item: item,
      list: list,
      recipients: list.recipientIDs.compactMap { user(id: $0) }.map(ListPage.Recipient.init),
      images: images,
      stillWanted: stillWanted,
      wanted: wanted,
      storeLinks: ItemPage.ordered(storeLinks(ofItem: id)),
      addedBy: addedBy,
      offersClaim: offersClaim(onItem: id),
      claims: isRecipient ? [] : giving.filter { $0.itemID == id }.map(ItemPage.ClaimLine.init)
    )
  }

  /// Whether I'll get this is offered for the item, on its page and in its row's context menu. False for an item
  /// that is not in the copy, and for a recipient of its list, as the copy shows the list. See
  /// `ItemPage.offersClaim(_:openGifts:)`.
  public func offersClaim(onItem id: String) -> Bool {
    guard let item = item(id: id), !isRecipient(ofList: item.listID) else { return false }
    return ItemPage.offersClaim(item, openGifts: giving)
  }

  /// Whether the session's user is a recipient of the list, as the copy shows it, with the journal applied: an
  /// accept that waits to be sent counts. False for a list that is not in the copy.
  func isRecipient(ofList id: String) -> Bool {
    list(id: id)?.recipientIDs.contains(session.userID) ?? false
  }
}
