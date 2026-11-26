import Foundation
import Testing

@testable import WishboneAPI
@testable import WishboneSession

/// What New list shows over the copy before the server answers, how the journal keeps it, and what a refusal of it
/// takes with it. See "Unsent changes" in `docs/spec.md`, and `Journal.swift`. `NewListTests` holds the rest against
/// the real server.
@Suite("A new list over the copy", .timeLimit(.minutes(1)))
struct NewListJournalTests {
  private func change(_ action: UnsentChange.Action, id: Int64 = 1) -> UnsentChange {
    UnsentChange(id: id, action: action, title: "Our house", key: "key")
  }

  private func created(_ id: String, name: String = "Our house", for recipientID: String = "me") -> CreatedList {
    CreatedList(
      id: id, name: name, description: "For the **new** place.", recipientID: recipientID,
      isForAChild: recipientID != "me", recipientName: recipientID == "me" ? "Robin" : "Emma",
      createdAt: Date(timeIntervalSince1970: 0))
  }

  private func createdItem(_ id: String, on listID: String, imageIDs: [String] = []) -> CreatedItem {
    CreatedItem(
      id: id, listID: listID, title: id, notes: nil, priceMinor: nil, topPriceMinor: nil, currency: nil,
      storeLinks: [], imageIDs: imageIDs, addedByID: "me", hidesClaimState: true,
      createdAt: Date(timeIntervalSince1970: 0))
  }

  private func move(_ itemID: String, from: String, to: String) -> UnsentChange.Action {
    .moveItem(ItemMove(itemID: itemID, fromListID: from, toListID: to, toListName: "List \(to)"))
  }

  private func list(_ id: String, name: String) -> ListRow {
    ListRow(
      id: id, name: name, description: nil, isPrimary: false, recipientIDs: ["me"], itemCount: 0,
      createdAt: Date(timeIntervalSince1970: 0), canEdit: true, canDelete: true, canInvite: true, canLeave: true,
      version: "\"1\"")
  }

  @Test("A new list shows at once by its stand-in ID, by name among the lists, with its one recipient and no items")
  func shownOverTheCopy() {
    let standIn = StandIn.make()
    let lists = LocalDatabase.applying(
      [change(.createList(created(standIn, for: "emma")))], to: [list("a", name: "Apples"), list("z", name: "Zoo")])
    #expect(lists.map(\.id) == ["a", standIn, "z"])
    let shown = lists[1]
    #expect(shown.name == "Our house")
    #expect(shown.description == "For the **new** place.")
    #expect(shown.recipientIDs == ["emma"])
    #expect(!shown.isPrimary)
    #expect(shown.itemCount == 0)
    #expect(shown.canEdit)
    #expect(shown.canDelete)
    #expect(!shown.canLeave)
    #expect(!shown.canInvite)
    #expect(shown.version == "")
  }

  @Test("An item added to a new list, an edit of it, and a move to it all show on it, in order")
  func laterChangesShow() {
    let standIn = StandIn.make()
    let lamp = StandIn.make()
    let car = ItemRow(
      id: "7", listID: "a", title: "Car", notes: nil, priceMinor: nil, topPriceMinor: nil, currency: nil,
      quantity: 1, isUnlimited: false, position: 0, addedByID: "me", createdAt: Date(timeIntervalSince1970: 0),
      images: [], primaryImage: nil, stillWanted: .hidden, myClaimedQuantity: .hidden, canEdit: true,
      canDelete: true, canClaim: false, canRefreshPrices: false, version: "\"1\"")
    let changes = [
      change(.createList(created(standIn))), change(.createItem(createdItem(lamp, on: standIn)), id: 2),
      change(.editList(listID: standIn, changes: ListChanges(name: "Home")), id: 3),
      change(move("7", from: "a", to: standIn), id: 4),
    ]
    let items = LocalDatabase.applying(changes, to: [car])
    #expect(items.filter { $0.listID == standIn }.map(\.id) == [lamp, "7"])
    let lists = LocalDatabase.applying(changes, to: [list("a", name: "Toys")], itemLists: ["7": "a"])
    #expect(lists.first { $0.id == standIn }?.name == "Home")
    #expect(lists.first { $0.id == standIn }?.itemCount == 2)
    #expect(lists.first { $0.id == "a" }?.itemCount == 0)
  }

  @Test("The journal keeps a new list as it was made, and its body sends recipient_id only for a child")
  func keptAndSent() async throws {
    let database = try LocalDatabase.inMemory()
    let mine = created(StandIn.make())
    let theirs = created(StandIn.make(), name: "Cousins", for: "emma")
    try await database.record([
      .init(.createList(mine), title: mine.name), .init(.createList(theirs), title: "Cousins"),
    ])
    let changes = try await database.unsentChangesAndStandIns().changes
    #expect(changes.map(\.action) == [.createList(mine), .createList(theirs)])
    #expect(changes.map(\.action.targetID) == [mine.id, theirs.id])
    #expect(changes.map(\.title) == ["Our house", "Cousins"])

    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    #expect(
      String(decoding: try encoder.encode(mine.newList), as: UTF8.self)
        == #"{"description":"For the **new** place.","name":"Our house"}"#)
    #expect(
      String(decoding: try encoder.encode(theirs.newList), as: UTF8.self)
        == #"{"description":"For the **new** place.","name":"Cousins","recipient_id":"emma"}"#)
    #expect(
      String(decoding: try encoder.encode(NewList(name: "Desk")), as: UTF8.self) == #"{"name":"Desk"}"#)
  }

  @Test(
    """
    A refused new list takes every change that needs it, and their uploads: its edits and delete, the items added \
    to it with their changes, and a move to it with the reorders on it. A later move away stays, and so do the \
    changes that don't need it
    """
  )
  func refusalTakesWhatNeedsIt() async throws {
    let database = try LocalDatabase.inMemory()
    let standIn = StandIn.make()
    let other = StandIn.make()
    let kite = StandIn.make()
    let photo = StandIn.make()
    let edited = StandIn.make()
    let stays = StandIn.make()
    let movedAway = StandIn.make()
    let bytes = Data([1, 2, 3])
    try await database.record([
      .init(.createList(created(standIn)), title: "Our house"),
      .init(.createList(created(other, name: "Shed")), title: "Shed"),
      // An item added to the list, with its photo, an edit with another photo, a move, and a delete.
      .init(.uploadImage(imageID: photo), title: "Kite", file: bytes),
      .init(.createItem(createdItem(kite, on: standIn, imageIDs: [photo])), title: "Kite"),
      .init(.uploadImage(imageID: edited), title: "Kite", file: bytes),
      .init(.editItem(itemID: kite, changes: ItemChanges(title: "Big kite", imageIDs: [edited])), title: "Kite"),
      .init(.reorderItem(ItemReorder(itemID: kite, position: 0)), title: "Kite"),
      .init(move(kite, from: standIn, to: "a"), title: "Kite"),
      // Ball moves in, is put first, and is edited: the edit stays, as it would be sent without the list.
      .init(move("7", from: "a", to: standIn), title: "Ball"),
      .init(.reorderItem(ItemReorder(itemID: "7", position: 0, neighbour: .before(kite))), title: "Ball"),
      .init(.editItem(itemID: "7", changes: ItemChanges(title: "Red ball")), title: "Ball"),
      // Car moves in, then on to another list, and is put first there: the move away and the reorder stay.
      .init(move("8", from: "a", to: standIn), title: "Car"),
      .init(move("8", from: standIn, to: "b"), title: "Car"),
      .init(.reorderItem(ItemReorder(itemID: "8", position: 0)), title: "Car"),
      // The list's own edit and delete.
      .init(.editList(listID: standIn, changes: ListChanges(name: "Home")), title: "Our house"),
      .init(.deleteList(listID: standIn), title: "Home"),
      // Changes that don't need the list.
      .init(.createItem(createdItem(stays, on: other)), title: "Rake"),
      .init(.createItem(createdItem(movedAway, on: "a")), title: "Lamp"),
      .init(.editList(listID: "a", changes: ListChanges(name: "Toys")), title: "Toys"),
      .init(.markBought(giftID: "15", isBought: true), title: "Kite"),
    ])
    let create = try #require(try await database.firstUnsentChange())
    try await database.refuse(
      create, refusal: APIError.Refusal(route: .createList, status: 403, code: .userDeactivated, detail: ""))

    let left = try await database.unsentChangesAndStandIns().changes.map(\.action)
    #expect(
      left == [
        .createList(created(other, name: "Shed")),
        .editItem(itemID: "7", changes: ItemChanges(title: "Red ball")),
        move("8", from: standIn, to: "b"),
        .reorderItem(ItemReorder(itemID: "8", position: 0)),
        .createItem(createdItem(stays, on: other)),
        .createItem(createdItem(movedAway, on: "a")),
        .editList(listID: "a", changes: ListChanges(name: "Toys")),
        .markBought(giftID: "15", isBought: true),
      ])
    #expect(try await database.unsentFile(photo) == nil)
    #expect(try await database.unsentFile(edited) == nil)
    // Only the list's create shows.
    let refusals = try await database.lateRefusals()
    #expect(refusals.map(\.action) == [.createList(created(standIn))])
  }

  @Test("A refused new list keeps the photo of an item that doesn't need it")
  func refusalKeepsOtherUploads() async throws {
    let database = try LocalDatabase.inMemory()
    let standIn = StandIn.make()
    let photo = StandIn.make()
    let item = StandIn.make()
    try await database.record([
      .init(.createList(created(standIn)), title: "Our house"),
      .init(.uploadImage(imageID: photo), title: "Lamp", file: Data([1])),
      .init(.createItem(createdItem(item, on: "a", imageIDs: [photo])), title: "Lamp"),
    ])
    let create = try #require(try await database.firstUnsentChange())
    try await database.refuse(
      create, refusal: APIError.Refusal(route: .createList, status: 403, code: .forbidden, detail: ""))
    #expect(try await database.unsentChangeCount() == 2)
    #expect(try await database.unsentFile(photo) == Data([1]))
  }

  @Test("A new list that can't be read stays in the journal, unsent, and shows nothing")
  func unreadable() async throws {
    let database = try LocalDatabase.inMemory()
    try await database.record(.createList(created(StandIn.make())), title: "Our house")
    try await database.change { database in
      try database.execute(sql: "UPDATE unsentChange SET patch = '{\"name\": 3}'")
    }
    #expect(try await database.firstUnsentChange() == nil)
    #expect(try await database.unsentChangeCount() == 1)
  }
}
