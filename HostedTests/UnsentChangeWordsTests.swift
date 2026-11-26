import Foundation
import Testing
import WishboneAPI
import WishboneSession
import WishboneUI

/// The words of the unsent changes: the count on the line "Can't reach {address}", the warning before Sign out, the
/// actions of a Giving row, and the lines of the alert of late refusals. See "Unsent changes, sign-out, and late
/// refusals" and "Sign out" in `docs/spec.md`, and "Words" in `docs/screens/gifts.md`.
@Suite("The words of the unsent changes", .timeLimit(.minutes(1)))
@MainActor
struct UnsentChangeWordsTests {
  @Test("The line and the warning count the unsent changes, one and more than one")
  func counts() {
    #expect(CantReach.unsentChanges(1) == "1 change will be sent when it's back.")
    #expect(CantReach.unsentChanges(3) == "3 changes will be sent when it's back.")
    #expect(SignOutWords.warning(unsentChanges: 0) == "You need a new login link to sign in again.")
    #expect(
      SignOutWords.warning(unsentChanges: 1)
        == "You need a new login link to sign in again. 1 change hasn't been sent and will be lost.")
    #expect(
      SignOutWords.warning(unsentChanges: 2)
        == "You need a new login link to sign in again. 2 changes haven't been sent and will be lost.")
  }

  @Test("A Giving row's actions are Mark bought and Mark not bought")
  func actions() {
    #expect(GiftWords.markBought(true) == "Mark bought")
    #expect(GiftWords.markBought(false) == "Mark not bought")
  }

  @Test("Each late refusal is a line: what the change did, then the app's words for the server's code")
  func lateRefusals() {
    let forbidden = LateRefusal(
      id: 1, action: .markBought(giftID: "15", isBought: true), title: "Kite",
      refusal: .init(route: .updateGift, status: 403, code: .forbidden, detail: "The server's words"))
    let gone = LateRefusal(
      id: 2, action: .markBought(giftID: "16", isBought: false), title: "Ball",
      refusal: .init(route: .updateGift, status: 404, code: .notFound, detail: "The server's words"))
    #expect(LateRefusalWords.line(forbidden) == "Marking Kite bought: You can't do this any more.")
    #expect(LateRefusalWords.line(gone) == "Marking Ball not bought: This is gone, or it isn't shared with you.")
    #expect(
      LateRefusalWords.message([forbidden, gone])
        == """
        Marking Kite bought: You can't do this any more.
        Marking Ball not bought: This is gone, or it isn't shared with you.
        """)
  }

  @Test("A late refusal of the from label, the note, or how many names the field and the item")
  func lateRefusalsOfGiftFields() {
    let refusal = APIError.Refusal(route: .updateGift, status: 403, code: .forbidden, detail: "The server's words")
    let fromLabel = LateRefusal(
      id: 1, action: .setFromLabel(giftID: "15", fromLabel: "Emma"), title: "Kite", refusal: refusal)
    let note = LateRefusal(id: 2, action: .setNote(giftID: "15", note: nil), title: "Kite", refusal: refusal)
    let quantity = LateRefusal(
      id: 3, action: .lowerQuantity(giftID: "15", quantity: 1), title: "Kite", refusal: refusal)
    #expect(LateRefusalWords.line(fromLabel) == "The from label of Kite: You can't do this any more.")
    #expect(LateRefusalWords.line(note) == "The note on Kite: You can't do this any more.")
    #expect(LateRefusalWords.line(quantity) == "How many of Kite: You can't do this any more.")
  }

  @Test("A late refusal of I won't get this, Keep it, or OK names the item, with the words for gift_given")
  func lateRefusalsOfAnswers() {
    let given = APIError.Refusal(route: .unclaimGift, status: 403, code: .giftGiven, detail: "The server's words")
    let forbidden = APIError.Refusal(
      route: .acknowledgeGift, status: 403, code: .forbidden, detail: "The server's words")
    let unclaim = LateRefusal(id: 1, action: .unclaim(giftID: "15"), title: "Kite", refusal: given)
    let keep = LateRefusal(
      id: 2, action: .acknowledge(giftID: "15", flag: "removed"), title: "Kite", refusal: forbidden)
    let ok = LateRefusal(
      id: 3, action: .acknowledge(giftID: "15", flag: "changed"), title: "Kite", refusal: forbidden)
    #expect(LateRefusalWords.line(unclaim) == "I won't get Kite: This gift was already given.")
    #expect(LateRefusalWords.line(keep) == "Keeping Kite: You can't do this any more.")
    #expect(LateRefusalWords.line(ok) == "The change to Kite: You can't do this any more.")
  }

  @Test("A late refusal of a pick of the occasion names the item, with the words for occasion_not_allowed")
  func lateRefusalOfAnOccasion() {
    let refusal = APIError.Refusal(
      route: .updateGift, status: 422, code: .occasionNotAllowed, detail: "The server's words")
    let pick = LateRefusal(
      id: 1,
      action: .setOccasion(
        giftID: "15", occasion: PickedOccasion(id: "7", kind: .custom, name: "Recital", date: "2040-06-01")),
      title: "Kite", refusal: refusal)
    #expect(
      LateRefusalWords.line(pick)
        == "The occasion of Kite: That occasion can't be used for this gift. Pick another.")
  }

  @Test("A late refusal of Edit list or Delete list names the list, with the words for list_has_other_recipients")
  func lateRefusalsOfLists() {
    let forbidden = APIError.Refusal(route: .updateList, status: 403, code: .forbidden, detail: "The server's words")
    let others = APIError.Refusal(
      route: .deleteList, status: 403, code: .listHasOtherRecipients, detail: "The server's words")
    let edit = LateRefusal(
      id: 1, action: .editList(listID: "9", changes: ListChanges(name: "Road trip")), title: "Trip",
      refusal: forbidden)
    let delete = LateRefusal(id: 2, action: .deleteList(listID: "9"), title: "Cousins", refusal: others)
    #expect(LateRefusalWords.line(edit) == "Editing Trip: You can't do this any more.")
    #expect(
      LateRefusalWords.line(delete)
        == "Deleting Cousins: Cousins has other recipients now, so it can't be deleted. You can leave it.")
  }

  @Test("A late refusal of Edit item or Delete names the item, with the words for too_many_images and forbidden")
  func lateRefusalsOfItems() {
    let tooMany = APIError.Refusal(route: .updateItem, status: 422, code: .tooManyImages, detail: "The server's words")
    let forbidden = APIError.Refusal(route: .deleteItem, status: 403, code: .forbidden, detail: "The server's words")
    let edit = LateRefusal(
      id: 1, action: .editItem(itemID: "4", changes: ItemChanges(title: "Box kite")), title: "Kite",
      refusal: tooMany)
    let delete = LateRefusal(id: 2, action: .deleteItem(itemID: "4", listID: "9"), title: "Kite", refusal: forbidden)
    #expect(LateRefusalWords.line(edit) == "Editing Kite: An item can have 5 photos.")
    #expect(LateRefusalWords.line(delete) == "Deleting Kite: You can't do this any more.")
  }

  @Test(
    "A refused move names the item, and the list it was to for cannot_edit_target_list, with no word about gifts"
  )
  func lateRefusalsOfMoves() {
    let move = UnsentChange.Action.moveItem(
      ItemMove(itemID: "4", fromListID: "9", toListID: "12", toListName: "Lego"))
    let target = APIError.Refusal(
      route: .updateItem, status: 403, code: .cannotEditTargetList, detail: "The server's words")
    let gone = APIError.Refusal(route: .updateItem, status: 404, code: .notFound, detail: "The server's words")
    let refusedTarget = LateRefusal(id: 1, action: move, title: "Kite", refusal: target)
    let refusedGone = LateRefusal(id: 2, action: move, title: "Kite", refusal: gone)
    #expect(LateRefusalWords.line(refusedTarget) == "Kite couldn't be moved. You can't add to Lego any more.")
    #expect(
      LateRefusalWords.line(refusedGone) == "Kite couldn't be moved. This is gone, or it isn't shared with you.")
    for line in [refusedTarget, refusedGone].map(LateRefusalWords.line) {
      #expect(!line.localizedStandardContains("gift"))
      #expect(!line.localizedStandardContains("claim"))
    }
  }

  @Test("A refused reorder reads as a refused move, with the words for the code, and no word about gifts")
  func lateRefusalsOfReorders() {
    let reorder = UnsentChange.Action.reorderItem(itemID: "4", position: 0)
    let forbidden = APIError.Refusal(route: .updateItem, status: 403, code: .forbidden, detail: "The server's words")
    let gone = APIError.Refusal(route: .updateItem, status: 404, code: .notFound, detail: "The server's words")
    let refusedForbidden = LateRefusalWords.line(LateRefusal(id: 1, action: reorder, title: "Kite", refusal: forbidden))
    let refusedGone = LateRefusalWords.line(LateRefusal(id: 2, action: reorder, title: "Kite", refusal: gone))
    #expect(refusedForbidden == "Kite couldn't be moved. You can't do this any more.")
    #expect(refusedGone == "Kite couldn't be moved. This is gone, or it isn't shared with you.")
    for line in [refusedForbidden, refusedGone] {
      #expect(!line.localizedStandardContains("gift"))
      #expect(!line.localizedStandardContains("claim"))
    }
  }

  @Test("A late refusal of a store link's price edit or its Remove names the item's edit")
  func lateRefusalsOfStoreLinks() {
    let forbidden = APIError.Refusal(
      route: .updateStoreLink, status: 403, code: .forbidden, detail: "The server's words")
    let gone = APIError.Refusal(route: .deleteStoreLink, status: 404, code: .notFound, detail: "The server's words")
    let edit = LateRefusal(
      id: 1,
      action: .editStoreLink(StoreLinkEdit(itemID: "4", storeLinkID: "8", priceMinor: 1999, editedAt: .now)),
      title: "Kite", refusal: forbidden)
    let remove = LateRefusal(
      id: 2, action: .deleteStoreLink(itemID: "4", storeLinkID: "8"), title: "Kite", refusal: gone)
    #expect(LateRefusalWords.line(edit) == "Editing Kite: You can't do this any more.")
    #expect(LateRefusalWords.line(remove) == "Editing Kite: This is gone, or it isn't shared with you.")
  }

  @Test("A late refusal of Decline names the list")
  func lateRefusalOfDecline() {
    let forbidden = APIError.Refusal(
      route: .declineInvitation, status: 403, code: .forbidden, detail: "The server's words")
    let decline = LateRefusal(
      id: 1, action: .declineInvitation(invitationID: "5"), title: "Cousins", refusal: forbidden)
    #expect(LateRefusalWords.line(decline) == "Declining the invitation to Cousins: You can't do this any more.")
  }

  @Test(
    """
    A late refusal of an item added by hand names the item, a blocked store's line names the store, and a refused \
    photo names its item
    """
  )
  func lateRefusalsOfAnAddByHand() {
    let created = CreatedItem(
      id: "stand-in-1", listID: "3", title: "Kite", notes: nil, priceMinor: nil, topPriceMinor: nil, currency: nil,
      storeLinks: [SearchStoreLink(url: "https://toys.example/kite", store: "toys.example")], imageIDs: [],
      addedByID: "7", hidesClaimState: true, createdAt: Date(timeIntervalSince1970: 0))
    let forbidden = LateRefusal(
      id: 1, action: .createItem(created), title: "Kite",
      refusal: .init(route: .createItem, status: 403, code: .forbidden, detail: "The server's words"))
    let blocked = LateRefusal(
      id: 2, action: .createItem(created), title: "Kite",
      refusal: .init(route: .createItem, status: 422, code: .storeBlocked, detail: "The server's words"))
    let photo = LateRefusal(
      id: 3, action: .uploadImage(imageID: "stand-in-2"), title: "Kite",
      refusal: .init(route: .uploadImage, status: 422, code: .imageInvalid, detail: "The server's words"))
    #expect(LateRefusalWords.line(forbidden) == "Adding Kite: You can't do this any more.")
    #expect(LateRefusalWords.line(blocked) == "Adding Kite: \(ErrorWords.blocked("toys.example"))")
    #expect(ErrorWords.blocked("toys.example") == "Links from toys.example are blocked on this Wishbone.")
    #expect(LateRefusalWords.line(photo) == "Your photo for Kite: \(ErrorWords.notAnImage)")
  }

  @Test("An invitation's line says who invited whom, to which list, and only who is invited once the inviter is gone")
  func invitationLines() {
    let line = { (invited: PendingInvitation.Invited, inviter: String?, onListPage: Bool) in
      InvitationWords.line(invited: invited, inviter: inviter, list: "Cousins", onListPage: onListPage)
    }
    #expect(line(.you, "Mom", false) == "Mom invited you to Cousins")
    #expect(line(.child(name: "Emma"), "Mom", false) == "Mom invited Emma to Cousins")
    #expect(line(.you, nil, false) == "You're invited to Cousins")
    #expect(line(.child(name: "Emma"), nil, false) == "Emma is invited to Cousins")
    #expect(line(.you, "Mom", true) == "Mom invited you to this list")
    #expect(line(.child(name: "Emma"), "Mom", true) == "Mom invited Emma to this list")
    #expect(line(.you, nil, true) == "You're invited to this list")
    #expect(line(.child(name: "Emma"), nil, true) == "Emma is invited to this list")
  }
}
