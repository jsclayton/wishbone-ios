import Foundation
import WishboneAPI

// Add again, on a given gift's page and a Received row. See `docs/screens/gift.md`, `docs/screens/gifts.md`,
// `docs/screens/add-form.md`, and "Add again" in the server's spec.
//
// **It is an unsent change.** The add form opens filled from the gift, and its Add is a create that can wait, as an
// add filled in by hand is: `POST /lists/{id}/items` with `from_gift_id`, and only the fields that the user changed
// beside it. The server copies the rest, the image as a new image.
//
// **The gift doesn't change.** Nothing here writes the gift, in the copy or on the server, so Received and the gift's
// page show nothing new to anyone.

extension SessionModel {
  /// The add form that Add again opens for the given gift, from its `can_add_again`: filled from the gift's title,
  /// image and price, as they were at reveal. Nil when the copy doesn't offer it: the gift is not in the copy, is not
  /// given, or has no `can_add_again`.
  ///
  /// Add to starts on the gift's list when the user can still edit it. Otherwise it starts on the user's own primary
  /// list when they received the gift, or else on the primary list of their child who did, the first by name, when
  /// the user can edit it. Failing that, it is the user's own primary list, where every form starts.
  public func addAgainForm(gift id: String) -> ItemDraft? {
    guard let gift = gift(id: id), gift.state == .given, gift.canAddAgain else { return nil }
    let filled = ItemDraft.AddAgain(
      giftID: gift.id, title: gift.title, image: gift.image, priceMinor: gift.priceMinor,
      topPriceMinor: gift.topPriceMinor, currency: gift.currency)
    return ItemDraft(addingAgain: filled, toList: startingList(forAddingAgain: gift))
  }

  /// The list that Add again starts on, or nil for the user's own primary list.
  func startingList(forAddingAgain gift: GiftRow) -> String? {
    if let list = list(id: gift.listID), list.canEdit { return list.id }
    let recipientIDs = gift.recipientIDs.value ?? []
    if recipientIDs.contains(session.userID) { return nil }
    let children = Set(user?.record?.childIDs ?? [])
    let child =
      recipientIDs
      .filter(children.contains)
      .compactMap { user(id: $0) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      .first
    guard let listID = child?.record?.primaryListID, let list = list(id: listID), list.canEdit else { return nil }
    return list.id
  }
}
