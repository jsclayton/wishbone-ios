import Foundation
import WishboneAPI

// A gift's page, from the copy: an open gift, as its giver reads it. The item's image, title and price, who the
// gift is for, each flag with every change of a changed item, then Bought, How many, Occasion with the reveal date,
// From, and Note. See `docs/screens/gift.md`, and "How each thing is reached" in `docs/spec.md`.
//
// **Only its giver sees an open gift.** The server never sends it to anyone else, so their copy never has it, and
// the page is the "not found" page for them. The page never says who else claimed the item: a gift's body doesn't
// say. Nothing here goes to a system surface or into the shared container.

/// What a gift's page shows. The session model builds it from the copy: see `SessionModel.giftPage(id:)`.
public struct GiftPage: Equatable, Sendable {
  public let gift: GiftRow

  /// Who the gift is for, as the copy names them, in the server's order. Nil when the giver can't see the list:
  /// the page then has no "For" line, and the list's name is not a link.
  public let recipients: [UserRow]?

  /// The gift's occasion, or only its reveal date when the giver can't see the occasion.
  public let occasion: ItemPage.ClaimLine.Occasion

  /// The occasions in the Occasion row's menu, soonest first. Empty when the row is not a button: the giver can't
  /// edit the gift, or can see none of the other recipients (`occasion_locked`). See
  /// `SessionModel.pickableOccasions(onList:)`.
  public let occasions: [OccasionRow]

  /// The occasion that Get another for a different occasion claims for. Nil when the row is not offered.
  public let anotherOccasion: OccasionRow?

  /// The flags that the app has words for, in the server's order.
  public let flags: [GivingGift.Flag]

  /// Each change of a changed item, old to new, in the order that the fields first changed. Empty when the gift
  /// has no `changed` flag. A field that the app doesn't know is left out.
  public let changes: [Change]

  /// Whether the title pushes the item's page: the viewer can still see the item, so the copy holds it. Never for
  /// an item that was removed, which the page shows as it was.
  public let linksItem: Bool

  /// Whether the list's name pushes the list's page: the giver can see the list, and the copy holds it.
  public let linksList: Bool

  /// Whether How many can go higher. See `SessionModel.offersRaise(onGift:)`.
  public let offersRaise: Bool

  /// A change of a changed item, with what its words need. See "Words" in `docs/screens/gift.md`.
  public enum Change: Equatable, Sendable {
    /// "Title: {old} → {new}".
    case title(old: String?, new: String?)

    /// "The notes changed". A note can be long, so the line doesn't quote it.
    case notes

    /// "How many: {old} → {new}".
    case quantity(old: Int?, new: Int?)

    /// "Now always wanted", or "No longer always wanted".
    case alwaysWanted(Bool)

    /// "Price: {old} → {new}", or "Price: {old} → none". Nil is no price.
    case price(old: GiftChange.Price?, new: GiftChange.Price?)

    /// "The photo changed".
    case photo

    /// "{store}: {old} → {new}": a store link's price. Nil is no price.
    case storeLinkPrice(store: String, old: GiftChange.Price?, new: GiftChange.Price?)

    /// "{store} was removed".
    case storeLinkRemoved(store: String)
  }
}

extension GiftPage.Change {
  /// The change for a line of a `changed` flag. Nil for a field that the app doesn't know, or a line of a shape
  /// that it can't read.
  init?(_ line: GiftChange) {
    switch line.field {
    case .title: self = .title(old: line.old.text, new: line.new.text)
    case .notes: self = .notes
    case .quantity: self = .quantity(old: line.old.number, new: line.new.number)
    case .isUnlimited:
      guard case .shown(.boolean(let now)?) = line.new else { return nil }
      self = .alwaysWanted(now)
    case .price: self = .price(old: line.old.price, new: line.new.price)
    case .primaryImage: self = .photo
    case .storeLinkPrice:
      guard let store = line.url.flatMap(Self.store) else { return nil }
      self = .storeLinkPrice(store: store, old: line.old.price, new: line.new.price)
    case .storeLinkRemoved:
      guard let store = line.url.flatMap(Self.store) else { return nil }
      self = .storeLinkRemoved(store: store)
    case .unknown: return nil
    }
  }

  /// The store of a store link's address, as the server names it: the host, with no `www.` and no trailing dot.
  static func store(ofURL url: String) -> String? {
    guard var host = URL(string: url)?.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
    if host.hasPrefix("www.") { host.removeFirst(4) }
    while host.hasSuffix(".") { host.removeLast() }
    return host.isEmpty ? nil : host
  }
}

extension Hideable<GiftChange.Value> {
  fileprivate var text: String? {
    if case .shown(.text(let text)?) = self { text } else { nil }
  }

  fileprivate var number: Int? {
    if case .shown(.number(let number)?) = self { number } else { nil }
  }

  fileprivate var price: GiftChange.Price? {
    if case .shown(.price(let price)?) = self { price } else { nil }
  }
}

extension SessionModel {
  /// The gift's page, from the copy. Nil when the page is the "not found" page: the gift is not in the copy, or it
  /// is not one of the session's user's open gifts. A gift that was unclaimed, merged, or restored from another
  /// device leaves the copy at the next sync, so it is the same as one that never was.
  public func giftPage(id: String) -> GiftPage? {
    guard let gift = gift(id: id), gift.state == .open, gift.giverID == session.userID else { return nil }
    let changes = (gift.flags.value ?? []).flatMap { flag -> [GiftChange] in
      if case .changed(let lines) = flag { lines } else { [] }
    }
    let isRemoved = gift.flags.value?.contains(.removed) == true
    return GiftPage(
      gift: gift,
      recipients: gift.recipientIDs.isHidden ? nil : (gift.recipientIDs.value ?? []).compactMap { user(id: $0) },
      occasion: ItemPage.ClaimLine(gift).occasion,
      occasions: canPickOccasion(ofGift: id) ? pickableOccasions(onList: gift.listID) : [],
      anotherOccasion: anotherOccasion(forGift: id),
      flags: givingGift(gift).flags,
      changes: changes.compactMap(GiftPage.Change.init),
      linksItem: !isRemoved && itemPage(id: gift.itemID) != nil,
      linksList: !gift.recipientIDs.isHidden && listPage(id: gift.listID) != nil,
      offersRaise: offersRaise(onGift: gift))
  }
}
