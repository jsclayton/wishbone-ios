import Foundation
import Testing

@testable import WishboneAPI
@testable import WishboneSession

/// What a reorder shows over the copy before the server answers, and how the journal keeps it. The overlay applies
/// the server's shift rule with every change to an item, in the journal's order, so the place that a reorder keeps
/// is the one that the server reads when it gets there. See "Where an item can land" and "What the windows show after
/// a drop" in `docs/spec.md`, and `Journal.swift`. `ReorderTests` holds the rest against the real server.
@Suite("A reorder over the copy", .timeLimit(.minutes(1)))
struct ReorderJournalTests {
  private func change(_ action: UnsentChange.Action, id: Int64 = 1) -> UnsentChange {
    UnsentChange(id: id, action: action, title: "Kettle", key: "key")
  }

  private func changes(_ actions: [UnsentChange.Action]) -> [UnsentChange] {
    actions.enumerated().map { change($1, id: Int64($0 + 1)) }
  }

  /// A reorder with only its place: as the first send leaves it, and as an earlier version of the app wrote it.
  private func reorder(_ itemID: String, to position: Int) -> UnsentChange.Action {
    .reorderItem(ItemReorder(itemID: itemID, position: position))
  }

  /// A reorder beside a neighbour, with the place that the list showed when it was made.
  private func reorder(_ itemID: String, to position: Int, _ neighbour: ItemNeighbour) -> UnsentChange.Action {
    .reorderItem(ItemReorder(itemID: itemID, position: position, neighbour: neighbour))
  }

  private func move(_ itemID: String, from: String, to: String) -> UnsentChange.Action {
    .moveItem(ItemMove(itemID: itemID, fromListID: from, toListID: to, toListName: "List \(to)"))
  }

  private func item(_ id: String, on listID: String, at position: Int) -> ItemRow {
    ItemRow(
      id: id, listID: listID, title: id, notes: nil, priceMinor: nil, topPriceMinor: nil, currency: nil, quantity: 1,
      isUnlimited: false, position: position, addedByID: "me", createdAt: Date(timeIntervalSince1970: 0), images: [],
      primaryImage: nil, stillWanted: .shown(1), myClaimedQuantity: .shown(0), canEdit: true, canDelete: true,
      canClaim: false, canRefreshPrices: false, version: "\"1\"")
  }

  /// The list "a" with the items given, in order, at 0 to n-1.
  private func list(_ ids: [String], on listID: String = "a") -> [ItemRow] {
    ids.enumerated().map { item($1, on: listID, at: $0) }
  }

  /// The items of the list as the overlay shows them, in the order it gives, with their places.
  private func shown(_ rows: [ItemRow], on listID: String) -> [String] {
    rows.filter { $0.listID == listID }.map { "\($0.id)@\($0.position)" }
  }

  @Test("A reorder puts the item at its place at once, and the others shift, down the list and up it")
  func shifts() throws {
    let rows = list(["1", "2", "3", "4"])
    #expect(
      shown(LocalDatabase.applying([change(reorder("1", to: 2))], to: rows), on: "a") == ["2@0", "3@1", "1@2", "4@3"])
    #expect(
      shown(LocalDatabase.applying([change(reorder("4", to: 1))], to: rows), on: "a") == ["1@0", "4@1", "2@2", "3@3"])
    // A place past the end is the last place, as the server takes it.
    #expect(
      shown(LocalDatabase.applying([change(reorder("2", to: 9))], to: rows), on: "a") == ["1@0", "3@1", "4@2", "2@3"])
    // In place: nothing moves.
    #expect(
      shown(LocalDatabase.applying([change(reorder("3", to: 2))], to: rows), on: "a") == ["1@0", "2@1", "3@2", "4@3"])
    // Everything else about the item stays as the server sent it.
    let moved = try #require(LocalDatabase.applying([change(reorder("1", to: 2))], to: rows).first { $0.id == "1" })
    #expect(moved.listID == "a" && moved.title == "1" && moved.version == "\"1\"")
  }

  @Test("A reorder changes only its own list, and no list's count")
  func onlyItsList() {
    let rows = list(["1", "2", "3"]) + list(["x", "y"], on: "b")
    let after = LocalDatabase.applying([change(reorder("3", to: 0))], to: rows)
    #expect(shown(after, on: "a") == ["3@0", "1@1", "2@2"])
    #expect(shown(after, on: "b") == ["x@0", "y@1"])
  }

  @Test("Three reorders in a row each read the places that the one before left")
  func threeInARow() {
    let rows = list(["1", "2", "3", "4"])
    let after = LocalDatabase.applying(
      changes([reorder("1", to: 3), reorder("4", to: 0), reorder("2", to: 2)]), to: rows)
    // 1 to the end: 2 3 4 1. 4 to the top: 4 2 3 1. 2 to the third place: 4 3 2 1.
    #expect(shown(after, on: "a") == ["4@0", "3@1", "2@2", "1@3"])
  }

  @Test(
    """
    A delete and a move close their gap, so a reorder after them reads the server's places: a delete or a move \
    before the item, a create after it, and a reorder of the created item by its stand-in ID
    """
  )
  func afterOtherChanges() {
    let rows = list(["1", "2", "3", "4"]) + list(["x"], on: "b")
    // 1 is deleted: 2 3 4 at 0 1 2. A reorder of 4 to 0 puts it first, as the server will.
    let deleted = LocalDatabase.applying(
      changes([.deleteItem(itemID: "1", listID: "a"), reorder("4", to: 0)]), to: rows)
    #expect(shown(deleted, on: "a") == ["4@0", "2@1", "3@2"])
    // 2 moves to b: 1 3 4 at 0 1 2, and 2 after x. A reorder of 4 to 1 puts it before 3.
    let moved = LocalDatabase.applying(changes([move("2", from: "a", to: "b"), reorder("4", to: 1)]), to: rows)
    #expect(shown(moved, on: "a") == ["1@0", "4@1", "3@2"])
    #expect(shown(moved, on: "b") == ["x@0", "2@1"])
    // A reorder of the moved item reorders it on the list that it is on now.
    let movedThenReordered = LocalDatabase.applying(
      changes([move("2", from: "a", to: "b"), reorder("2", to: 0)]), to: rows)
    #expect(shown(movedThenReordered, on: "b") == ["2@0", "x@1"])
    #expect(shown(movedThenReordered, on: "a") == ["1@0", "3@1", "4@2"])
    // An item added by hand, then reordered by its stand-in ID to the top.
    let standIn = StandIn.make()
    let created = CreatedItem(
      id: standIn, listID: "a", title: "Kettle", notes: nil, priceMinor: nil, topPriceMinor: nil, currency: nil,
      storeLinks: [], imageIDs: [], addedByID: "me", hidesClaimState: true, createdAt: Date(timeIntervalSince1970: 0))
    let added = LocalDatabase.applying(changes([.createItem(created), reorder(standIn, to: 0)]), to: rows)
    #expect(shown(added, on: "a") == ["\(standIn)@0", "1@1", "2@2", "3@3", "4@4"])
    // A reorder then a move: the item leaves from its new place, and the gap closes there.
    let reorderedThenMoved = LocalDatabase.applying(
      changes([reorder("4", to: 0), move("4", from: "a", to: "b")]), to: rows)
    #expect(shown(reorderedThenMoved, on: "a") == ["1@0", "2@1", "3@2"])
    #expect(shown(reorderedThenMoved, on: "b") == ["x@0", "4@1"])
  }

  @Test("A reorder of an item that isn't there, which a pull removed or a delete took out, changes nothing")
  func gone() {
    let rows = list(["1", "2", "3"])
    #expect(shown(LocalDatabase.applying([change(reorder("9", to: 0))], to: rows), on: "a") == ["1@0", "2@1", "3@2"])
    let deleted = LocalDatabase.applying(
      changes([.deleteItem(itemID: "3", listID: "a"), reorder("3", to: 0)]), to: rows)
    #expect(shown(deleted, on: "a") == ["1@0", "2@1"])
  }

  @Test("The items keep the places of the copy, gaps and all, where no change touches them")
  func keepsTheCopysPlaces() {
    // A parent who isn't a recipient doesn't see the items that others claimed in full: the places have gaps.
    let rows = [item("1", on: "a", at: 0), item("2", on: "a", at: 2), item("3", on: "a", at: 5)]
    // 3 goes before 2, at 2: 2 shifts to 3, and the gap at 1 stays, as the server keeps the hidden item there.
    let after = LocalDatabase.applying([change(reorder("3", to: 2))], to: rows)
    #expect(shown(after, on: "a") == ["1@0", "3@2", "2@3"])
  }

  @Test(
    """
    A list's move names the neighbour as the page drew the items: after the item before the drop going down, before \
    the item at it going up, and none where the item stays or the drop is off the list
    """
  )
  func neighbourOfAMove() {
    let ids = ["a", "b", "c", "d"]
    #expect(ItemNeighbour(movingFrom: 0, to: 4, in: ids) == .after("d"))
    #expect(ItemNeighbour(movingFrom: 0, to: 2, in: ids) == .after("b"))
    #expect(ItemNeighbour(movingFrom: 3, to: 0, in: ids) == .before("a"))
    #expect(ItemNeighbour(movingFrom: 3, to: 1, in: ids) == .before("b"))
    for (index, offset) in [(1, 1), (1, 2), (0, 5), (0, -1), (4, 0)] {
      #expect(ItemNeighbour(movingFrom: index, to: offset, in: ids) == nil)
    }
  }

  @Test("Beside its neighbour, an item takes the place that the server's reorder gives it, from either side")
  func placeBeside() {
    // Down the list, the neighbour closes up first. Up it, the neighbour makes room.
    #expect(ItemNeighbour.after("n").place(movingFrom: 0, besideAt: 3) == 3)
    #expect(ItemNeighbour.after("n").place(movingFrom: 5, besideAt: 3) == 4)
    #expect(ItemNeighbour.before("n").place(movingFrom: 0, besideAt: 3) == 2)
    #expect(ItemNeighbour.before("n").place(movingFrom: 5, besideAt: 3) == 3)
  }

  @Test(
    """
    A reorder shows beside its neighbour where the list has it now, not at the place that it kept: a created item \
    that the server put after an item that the user doesn't see
    """
  )
  func besideTheNeighbour() {
    // The create's answer put Kite at 3, after a hidden item at 2. The reorder kept 2, the place that the list showed.
    let rows = [item("A", on: "a", at: 0), item("B", on: "a", at: 1), item("Kite", on: "a", at: 3)]
    let after = LocalDatabase.applying([change(reorder("A", to: 2, .after("Kite")))], to: rows)
    #expect(shown(after, on: "a") == ["B@0", "Kite@2", "A@3"])
    let before = LocalDatabase.applying([change(reorder("A", to: 1, .before("Kite")))], to: rows)
    // Right before Kite: after the hidden item, which the server shifts to 1.
    #expect(shown(before, on: "a") == ["B@0", "A@2", "Kite@3"])
    // A neighbour that is gone, or on another list, leaves the place that the reorder kept. Read from x's place, A
    // would go to 2.
    let gone = LocalDatabase.applying([change(reorder("A", to: 1, .after("Z")))], to: rows)
    #expect(shown(gone, on: "a") == ["B@0", "A@1", "Kite@3"])
    let elsewhere = LocalDatabase.applying(
      [change(reorder("A", to: 1, .after("x")))], to: rows + [item("x", on: "b", at: 2)])
    #expect(shown(elsewhere, on: "a") == ["B@0", "A@1", "Kite@3"])
  }

  @Test(
    """
    The first send reads the place from the neighbour as the copy has it, and the row keeps it with no neighbour, so a \
    resend sends the same place whatever the copy says then
    """
  )
  func resolvedOnce() async throws {
    let database = try LocalDatabase.inMemory()
    try await database.change { database in
      for row in [item("A", on: "a", at: 0), item("B", on: "a", at: 1), item("Kite", on: "a", at: 3)] {
        try row.save(database)
      }
    }
    try await database.record(reorder("A", to: 2, .after("Kite")), title: "Kettle")
    let first = try #require(try await database.firstUnsentChange())
    let sent = try await database.resolvingPlace(of: first)
    #expect(sent.action == reorder("A", to: 3))
    #expect(sent.key == first.key)
    #expect(try await database.firstUnsentChange()?.action == reorder("A", to: 3))

    // The copy changes before the resend: the row keeps its place.
    try await database.change { database in try self.item("Kite", on: "a", at: 1).save(database) }
    let resend = try await database.resolvingPlace(of: try #require(try await database.firstUnsentChange()))
    #expect(resend.action == reorder("A", to: 3))
    #expect(resend.key == first.key)
  }

  @Test("The journal reads a reorder back as it was saved, and it sends only position")
  func roundTrip() async throws {
    let database = try LocalDatabase.inMemory()
    let action = reorder("7", to: 3)
    try await database.record(action, title: "Kettle")
    let (saved, _) = try await database.unsentChangesAndStandIns()
    #expect(saved.map(\.action) == [action])
    #expect(saved.first?.action.targetID == "7")
    #expect(saved.first?.action.isToAnItem == true)
    #expect(saved.first?.action.isToAGift == false)

    let body = try JSONEncoder().encode(ItemChanges(position: 3))
    #expect(String(decoding: body, as: UTF8.self) == #"{"position":3}"#)

    // With its neighbour, after or before.
    for action in [reorder("7", to: 3, .after("9")), reorder("7", to: 3, .before("9"))] {
      try await database.record(action, title: "Kettle")
    }
    let (withNeighbours, _) = try await database.unsentChangesAndStandIns()
    #expect(
      withNeighbours.dropFirst().map(\.action) == [reorder("7", to: 3, .after("9")), reorder("7", to: 3, .before("9"))])
  }

  @Test("A row that an earlier version of the app wrote, with only its place, reads and sends as it did")
  func earlierRow() async throws {
    let database = try LocalDatabase.inMemory()
    try await database.record(reorder("7", to: 2, .after("9")), title: "Kettle")
    try await database.change { database in
      try database.execute(sql: "UPDATE unsentChange SET patch = ?", arguments: [#"{"position":4}"#])
    }
    let change = try #require(try await database.firstUnsentChange())
    #expect(change.action == reorder("7", to: 4))
    #expect(try await database.resolvingPlace(of: change) == change)
  }

  @Test("A refused create takes the reorder of its item with it")
  func refusedCreate() async throws {
    let database = try LocalDatabase.inMemory()
    let standIn = StandIn.make()
    let created = CreatedItem(
      id: standIn, listID: "a", title: "Kettle", notes: nil, priceMinor: nil, topPriceMinor: nil, currency: nil,
      storeLinks: [], imageIDs: [], addedByID: "me", hidesClaimState: true, createdAt: Date(timeIntervalSince1970: 0))
    try await database.record([
      .init(.createItem(created), title: "Kettle"), .init(reorder(standIn, to: 0), title: "Kettle"),
    ])
    let create = try #require(try await database.firstUnsentChange())
    try await database.refuse(
      create, refusal: APIError.Refusal(route: .createItem, status: 403, code: .forbidden, detail: ""))
    #expect(try await database.unsentChangeCount() == 0)
    #expect(try await database.lateRefusals().count == 1)
  }

  @Test(
    "A reorder that can't be read stays in the journal, unsent, and shows nothing",
    arguments: [
      #"{"position": -1}"#, #"{"position": "2"}"#, #"{}"#, #"{"position": 2, "list_id": "b"}"#,
      #"{"position": 2, "after": "8", "before": "9"}"#, #"{"position": 2, "after": 8}"#,
    ]
  )
  func unreadable(patch: String) async throws {
    let database = try LocalDatabase.inMemory()
    try await database.record(reorder("7", to: 2), title: "Kettle")
    try await database.change { database in
      try database.execute(sql: "UPDATE unsentChange SET patch = ?", arguments: [patch])
    }
    #expect(try await database.firstUnsentChange() == nil)
    #expect(try await database.unsentChangeCount() == 1)
  }

  @Test("The journal keeps a reorder under a name of its own, and the names before it stay")
  func kindName() {
    #expect(UnsentChangeRow.Kind.reorderItem.rawValue == "reorderItem")
    #expect(UnsentChangeRow.Kind(rawValue: "moveItem") == .moveItem)
  }
}
