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
    storeLinks.first.flatMap { URL(string: $0.url) }
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
    storeLinks(ofItem: id).min { $0.position < $1.position }.flatMap { URL(string: $0.url) }
  }

  /// The item's page, from the copy. Nil when the page is the "not found" page: the item is not in the copy, which
  /// is the same for an item that was deleted and one that the session's user can no longer see.
  public func itemPage(id: String) -> ItemPage? {
    guard let item = item(id: id), let list = list(id: item.listID) else { return nil }

    let stillWanted: ItemPage.StillWanted? =
      switch item.stillWanted {
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
      storeLinks: storeLinks(ofItem: id).sorted { $0.position < $1.position },
      addedBy: addedBy
    )
  }
}
