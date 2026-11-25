import Foundation
import WishboneAPI
import WishboneSession

/// The words of the Gifts tab: a Giving heading, a row's lines, each flag, and the badge as VoiceOver reads it. See
/// "Words" in `docs/screens/gifts.md`, and "Accessibility" in `docs/screens/tabs-and-sidebar.md`.
public enum GiftWords {
  /// "For Mom and Dad · Christmas", or "For Mom and Dad · Hidden until Mar 4" when the giver can't see the
  /// occasion. With no recipients that the giver can see, only "Christmas" or "Hidden until Mar 4".
  public static func heading(_ group: GivingGroup) -> String {
    heading(recipients: group.recipients?.map(\.name), occasion: group.occasion)
  }

  /// The heading from the recipients' names, nil when the giver can't see the list, and the occasion.
  public static func heading(recipients: [String]?, occasion: ItemPage.ClaimLine.Occasion) -> String {
    let occasion = self.occasion(occasion)
    guard let recipients, !recipients.isEmpty else { return occasion }
    let names = recipients.formatted(.list(type: .and))
    return String(
      localized: "For \(names) · \(occasion)", bundle: #bundle,
      comment: "A Giving heading: who the gifts are for, then the occasion or the reveal date")
  }

  /// The occasion's name, or "Hidden until Mar 4" when the giver can't see it.
  public static func occasion(_ occasion: ItemPage.ClaimLine.Occasion) -> String {
    switch occasion {
    case .named(let name): name
    case .hiddenUntil(let date): hiddenUntil(date)
    }
  }

  /// "Hidden until Dec 26": the gift's reveal date.
  public static func hiddenUntil(_ date: Date) -> String {
    let day = date.formatted(.dateTime.month(.abbreviated).day())
    return String(localized: "Hidden until \(day)", bundle: #bundle)
  }

  /// What a raise of how many that didn't raise says, in place. Nil for a raise that the server granted: the
  /// number says it. The words never say who else claimed.
  public static func raiseResult(of outcome: RaiseOutcome, address: InstanceAddress) -> String? {
    switch outcome {
    case .raised, .notOffered:
      return nil
    case .someoneElseGotIt:
      return ErrorWords.someoneElseGotIt
    case .unreachable:
      return String(localized: "Can't reach \(address.text). The number didn't change.", bundle: #bundle)
    case .refused(let refusal):
      return ErrorWords.words(for: refusal) ?? ErrorWords.fault
    case .failed:
      return ErrorWords.fault
    }
  }

  /// What VoiceOver reads as the value of the stepper of how many: "2", or "2, can't go higher".
  public static func howManyValue(_ quantity: Int, canRaise: Bool) -> String {
    canRaise
      ? quantity.formatted()
      : String(
        localized: "\(quantity), can't go higher", bundle: #bundle,
        comment: "VoiceOver: how many of a gift, when the giver can't raise it")
  }

  /// "3 of these", for a gift of more than one.
  public static func howMany(_ quantity: Int) -> String {
    String(localized: "\(quantity) of these", bundle: #bundle)
  }

  /// "From Emma": the gift's from label.
  public static func from(_ label: String) -> String {
    String(localized: "From \(label)", bundle: #bundle, comment: "Who a gift in Giving is from, as its giver set it")
  }

  /// "Bought", or "Not bought".
  public static func bought(_ isBought: Bool) -> String {
    isBought
      ? String(localized: "Bought", bundle: #bundle)
      : String(localized: "Not bought", bundle: #bundle)
  }

  /// The action of a Giving row that sets the mark: "Mark bought", or "Mark not bought".
  public static func markBought(_ isBought: Bool) -> String {
    isBought
      ? String(localized: "Mark bought", bundle: #bundle)
      : String(localized: "Mark not bought", bundle: #bundle)
  }

  /// "Needs attention": said in words on the row, never by color alone.
  public static var needsAttention: String {
    String(localized: "Needs attention", bundle: #bundle)
  }

  /// The words of a flag.
  public static func flag(_ flag: GivingGift.Flag) -> String {
    switch flag {
    case .changed:
      String(localized: "The item changed", bundle: #bundle)
    case .removed:
      String(localized: "Removed from the list", bundle: #bundle)
    case .moved(let list?):
      String(localized: "Moved to \(list)", bundle: #bundle, comment: "A gift's flag: the item moved to the list")
    case .moved(nil):
      String(localized: "Moved to another list", bundle: #bundle)
    case .occasionMoved(let occasion?):
      nowFor(occasion)
    case .occasionMoved(nil):
      String(localized: "Moved to another occasion", bundle: #bundle)
    case .noLongerShared:
      String(localized: "No longer shared with you", bundle: #bundle)
    case .restored(let name?):
      String(
        localized: "\(name) says they didn't get this", bundle: #bundle,
        comment: "A gift's flag: the recipient, by name, restored the gift")
    case .restored(nil):
      String(localized: "Marked as not received", bundle: #bundle)
    case .recipientsChanged(let names?) where !names.isEmpty:
      nowFor(names.formatted(.list(type: .and)))
    case .recipientsChanged:
      String(localized: "The recipients changed", bundle: #bundle)
    }
  }

  /// "Now for Mom": the occasion that the gift moved to, or the gift's recipients now.
  private static func nowFor(_ what: String) -> String {
    String(
      localized: "Now for \(what)", bundle: #bundle,
      comment: "A gift's flag: the occasion that the gift moved to, or its recipients now, by name")
  }

  // MARK: - A gift's page

  /// "For Dad", "For Mom and Dad": who a gift is for, on its page.
  public static func forLine(_ names: [String]) -> String {
    let names = names.formatted(.list(type: .and))
    return String(localized: "For \(names)", bundle: #bundle, comment: "Who a gift is for, on its page, by name")
  }

  /// The words of a flag on a gift's page. The removed, no-longer-shared and occasion flags say more there than
  /// on a row. The rest are the row's words.
  public static func pageFlag(_ flag: GivingGift.Flag) -> String {
    switch flag {
    case .removed:
      String(localized: "This was removed from the list. You can still give it.", bundle: #bundle)
    case .noLongerShared:
      String(localized: "This list is no longer shared with you. You can still give this, or not.", bundle: #bundle)
    case .occasionMoved(let occasion?):
      String(
        localized: "The occasion changed. It's now for \(occasion).", bundle: #bundle,
        comment: "A gift's flag on its page: the gift's occasion stopped applying, and it moved to this one")
    case .occasionMoved(nil):
      String(localized: "The occasion changed.", bundle: #bundle)
    case .changed, .moved, .restored, .recipientsChanged:
      self.flag(flag)
    }
  }

  /// A change of a changed item, old to new: "Title: Kite → Red kite", "Price: $20 → none".
  public static func change(_ change: GiftPage.Change) -> String {
    switch change {
    case .title(let old, let new):
      let old = old ?? "", new = new ?? ""
      return String(
        localized: "Title: \(old) → \(new)", bundle: #bundle, comment: "A change of an item's title, old to new")
    case .notes:
      return String(localized: "The notes changed", bundle: #bundle)
    case .quantity(let old, let new):
      let old = old.map { $0.formatted() } ?? none, new = new.map { $0.formatted() } ?? none
      return String(
        localized: "Wants: \(old) → \(new)", bundle: #bundle,
        comment: "A change of how many of an item its recipients want, old to new")
    case .alwaysWanted(true):
      return String(localized: "Now always wanted", bundle: #bundle)
    case .alwaysWanted(false):
      return String(localized: "No longer always wanted", bundle: #bundle)
    case .price(let old, let new):
      let old = price(old), new = price(new)
      return String(
        localized: "Price: \(old) → \(new)", bundle: #bundle,
        comment: "A change of an item's price, old to new. A price can be the word for none")
    case .photo:
      return String(localized: "The photo changed", bundle: #bundle)
    case .storeLinkPrice(let store, let old, let new):
      let old = price(old), new = price(new)
      return String(
        localized: "\(store): \(old) → \(new)", bundle: #bundle,
        comment:
          "A change of a store link's price, old to new, after the store's name. A price can be the word for none")
    case .storeLinkRemoved(let store):
      return String(
        localized: "\(store) was removed", bundle: #bundle, comment: "A change of an item: the store link was removed")
    }
  }

  /// A price in a change, or "none".
  private static func price(_ price: GiftChange.Price?) -> String {
    guard let price else { return none }
    return PriceWords.page(priceMinor: price.priceMinor, topPriceMinor: price.topPriceMinor, currency: price.currency)
      ?? none
  }

  /// "none": no value, in a change.
  private static var none: String {
    String(localized: "none", bundle: #bundle, comment: "No value, in a change of an item: no price")
  }

  /// What VoiceOver reads for the Gifts tab with its badge: "Gifts, 2 need attention".
  public static func tab(badge: Int) -> String {
    String(
      localized: "Gifts, \(badge) need attention", bundle: #bundle,
      comment: "The Gifts tab, as VoiceOver reads it, with how many open gifts need attention")
  }
}
