import Foundation
import WishboneAPI

// I won't get this, and the answers to a change: OK and Keep it. See "I won't get this", "OK" and "Keep it" in
// `docs/screens/gift.md`, "I won't get this" in `docs/screens/gifts.md`, and "Unsent changes" in `docs/spec.md`.
//
// - Each is an unsent change: it shows at once, in every window, and reaches the instance when it answers.
// - I won't get this takes the gift out of Giving at once. A window that shows the gift's page then shows the "not
//   found" page, and the window that did it closes the page.
// - OK clears only its own flag. Keep it is the answer to `removed`: it clears that flag, and the gift is given at
//   its reveal.
//
// **Only the giver sees an open gift.** Nothing here says who else claimed the item, and nothing goes to a system
// surface or into the shared container.

extension GivingGift.Flag {
  /// The flag's code, as the server writes it: what its answer names.
  public var code: String {
    switch self {
    case .changed: "changed"
    case .removed: "removed"
    case .moved: "moved"
    case .occasionMoved: "occasion_moved"
    case .noLongerShared: "no_longer_shared"
    case .restored: "restored"
    case .recipientsChanged: "recipients_changed"
    }
  }

  /// Whether the flag's answer is Keep it, and not OK: the item was removed from its list.
  public var isAnsweredByKeepIt: Bool {
    self == .removed
  }
}

extension SessionModel {
  /// I won't get this: unclaims the giver's open gift, as an unsent change. The gift leaves Giving and its page at
  /// once, in every window, and a sync sends it. When the server accepts it, the quantity goes back to all givers.
  ///
  /// It does nothing for a gift that the copy doesn't hold, that is not the giver's open gift, or that has no
  /// `can_delete`. It returns when the change is in the journal and published, and doesn't wait for the sync.
  public func unclaim(gift id: String) async {
    guard !hasEnded, let gift = gift(id: id), gift.state == .open, gift.giverID == session.userID, gift.canDelete
    else { return }
    await record(.unclaim(giftID: id), title: gift.title)
  }

  /// OK, or Keep it for the "removed" flag: answers one flag of the giver's open gift, as an unsent change. That flag
  /// leaves the gift at once, in every window, and no other. A sync sends it.
  ///
  /// It does nothing for a gift that the copy doesn't hold, that has no `can_acknowledge`, or that doesn't have the
  /// flag.
  public func answer(_ flag: GivingGift.Flag, ofGift id: String) async {
    guard !hasEnded, let gift = gift(id: id), gift.state == .open, gift.canAcknowledge,
      gift.flags.value?.contains(where: { $0.code == flag.code }) == true
    else { return }
    await record(.acknowledge(giftID: id, flag: flag.code), title: gift.title)
  }
}
