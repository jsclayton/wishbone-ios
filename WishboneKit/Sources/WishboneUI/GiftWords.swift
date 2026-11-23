import Foundation
import WishboneSession

/// The words of the Gifts tab: a Giving heading, a row's lines, each flag, and the badge as VoiceOver reads it. See
/// "Words" in `docs/screens/gifts.md`, and "Accessibility" in `docs/screens/tabs-and-sidebar.md`.
public enum GiftWords {
  /// "For Mom and Dad · Christmas", or "For Mom and Dad · Hidden until Mar 4" when the giver can't see the
  /// occasion. With no recipients that the giver can see, only "Christmas" or "Hidden until Mar 4".
  public static func heading(_ group: GivingGroup) -> String {
    let occasion = occasion(group.occasion)
    guard let recipients = group.recipients, !recipients.isEmpty else { return occasion }
    let names = recipients.map(\.name).formatted(.list(type: .and))
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

  /// What VoiceOver reads for the Gifts tab with its badge: "Gifts, 2 need attention".
  public static func tab(badge: Int) -> String {
    String(
      localized: "Gifts, \(badge) need attention", bundle: #bundle,
      comment: "The Gifts tab, as VoiceOver reads it, with how many open gifts need attention")
  }
}
