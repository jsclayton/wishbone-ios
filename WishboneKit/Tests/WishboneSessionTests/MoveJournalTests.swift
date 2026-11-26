import Foundation
import Testing

@testable import WishboneAPI
@testable import WishboneSession

/// What a move shows over the copy before the server answers, and how the journal keeps it. See "What the windows
/// show after a drop" and "Unsent changes" in `docs/spec.md`, and `Journal.swift`. `MoveTests` holds the rest against
/// the real server.
@Suite("A move over the copy", .timeLimit(.minutes(1)))
struct MoveJournalTests {
  private func change(_ action: UnsentChange.Action, id: Int64 = 1) -> UnsentChange {
    UnsentChange(id: id, action: action, title: "Kettle", key: "key")
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

  /// The list of each item, by its ID, as the snapshot gives the lists' overlay.
  private func places(_ items: [ItemRow]) -> [String: String] {
    Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.listID) })
  }

  private func list(_ id: String, items: Int) -> ListRow {
    ListRow(
      id: id, name: "List \(id)", description: nil, isPrimary: false, recipientIDs: ["me"], itemCount: items,
      createdAt: Date(timeIntervalSince1970: 0), canEdit: true, canDelete: true, canInvite: true, canLeave: true,
      version: "\"1\"")
  }

  @Test(
    "A moved item shows after the last item of the other list, the old list closes its gap, and both lists count it"
  )
  func atTheEnd() throws {
    let rows = [
      item("1", on: "a", at: 0), item("2", on: "a", at: 1), item("3", on: "a", at: 2), item("4", on: "b", at: 6),
    ]
    let shown = LocalDatabase.applying([change(move("2", from: "a", to: "b"))], to: rows)
    #expect(shown.filter { $0.listID == "a" }.map(\.id) == ["1", "3"])
    // The gap closes, as the server's shift rule closes it, so a reorder after the move reads the server's places.
    #expect(shown.filter { $0.listID == "a" }.map(\.position) == [0, 1])
    #expect(shown.filter { $0.listID == "b" }.map(\.id) == ["4", "2"])
    #expect(shown.filter { $0.listID == "b" }.map(\.position) == [6, 7])
    // Everything else about the item stays as the server sent it.
    let moved = try #require(shown.first { $0.id == "2" })
    #expect(moved.title == "2" && moved.stillWanted == .shown(1) && moved.version == "\"1\"")

    let lists = LocalDatabase.applying(
      [change(move("2", from: "a", to: "b"))], to: [list("a", items: 3), list("b", items: 1)],
      itemLists: places(rows))
    #expect(lists.map(\.itemCount) == [2, 2])
  }

  @Test("Two moves, a move after a create, and a move of an item that is on the list already, in the journal's order")
  func inOrder() {
    let rows = [item("1", on: "a", at: 0), item("2", on: "b", at: 0)]
    let standIn = StandIn.make()
    let created = CreatedItem(
      id: standIn, listID: "a", title: "Kettle", notes: nil, priceMinor: nil, topPriceMinor: nil, currency: nil,
      storeLinks: [], imageIDs: [], addedByID: "me", hidesClaimState: true, createdAt: Date(timeIntervalSince1970: 0))
    let shown = LocalDatabase.applying(
      [
        change(.createItem(created)), change(move(standIn, from: "a", to: "b"), id: 2),
        change(move("1", from: "a", to: "c"), id: 3), change(move("1", from: "c", to: "b"), id: 4),
        change(move("2", from: "b", to: "b"), id: 5), change(move("9", from: "a", to: "b"), id: 6),
      ], to: rows)
    #expect(shown.filter { $0.listID == "a" }.isEmpty)
    #expect(shown.filter { $0.listID == "b" }.map(\.id) == ["2", standIn, "1"])
    #expect(shown.filter { $0.listID == "b" }.map(\.position) == [0, 1, 2])
    #expect(shown.filter { $0.listID == "c" }.isEmpty)
  }

  @Test("An edit after a move shows over the moved item, and a delete after it takes it out of the new list")
  func withEditsAndDeletes() {
    let rows = [item("1", on: "a", at: 0), item("2", on: "b", at: 0)]
    let edited = LocalDatabase.applying(
      [
        change(move("1", from: "a", to: "b")),
        change(.editItem(itemID: "1", changes: ItemChanges(title: "Kite")), id: 2),
      ],
      to: rows)
    #expect(edited.filter { $0.listID == "b" }.map(\.title) == ["2", "Kite"])
    let deleted = LocalDatabase.applying(
      [change(move("1", from: "a", to: "b")), change(.deleteItem(itemID: "1", listID: "b"), id: 2)], to: rows)
    #expect(deleted.map(\.id) == ["2"])
    let lists = LocalDatabase.applying(
      [change(move("1", from: "a", to: "b")), change(.deleteItem(itemID: "1", listID: "b"), id: 2)],
      to: [list("a", items: 1), list("b", items: 1)], itemLists: places(rows))
    #expect(lists.map(\.itemCount) == [0, 1])
  }

  @Test(
    """
    The lists count a waiting move or delete only where the items show it: never for an item that the copy doesn't \
    hold, a move to the list that the item is on, or a second delete
    """
  )
  func countsOnlyWhatShows() {
    let rows = [item("1", on: "a", at: 0), item("2", on: "b", at: 0)]
    // Each list counts more than the items here, as for a giver who doesn't see every item, so no count is near 0.
    let lists = [list("a", items: 3), list("b", items: 3), list("c", items: 3)]
    func counts(_ actions: [UnsentChange.Action]) -> [Int] {
      let changes = actions.enumerated().map { change($1, id: Int64($0 + 1)) }
      return LocalDatabase.applying(changes, to: lists, itemLists: places(rows)).map(\.itemCount)
    }
    // A pull removed item 9: neither its move nor its delete shows, so no count changes.
    #expect(counts([move("9", from: "a", to: "b")]) == [3, 3, 3])
    #expect(counts([.deleteItem(itemID: "9", listID: "a")]) == [3, 3, 3])
    // Item 2 is on b already.
    #expect(counts([move("2", from: "a", to: "b")]) == [3, 3, 3])
    // Item 1 is deleted twice: it counts one fewer once.
    #expect(counts([.deleteItem(itemID: "1", listID: "a"), .deleteItem(itemID: "1", listID: "a")]) == [2, 3, 3])
    // A delete counts on the list the item is on now, after a move, whatever list the delete kept.
    #expect(counts([move("1", from: "a", to: "c"), .deleteItem(itemID: "1", listID: "a")]) == [2, 3, 3])
    // Item 1 goes to c, then back to a: each list counts it where it is.
    #expect(counts([move("1", from: "a", to: "c")]) == [2, 3, 4])
    #expect(counts([move("1", from: "a", to: "c"), move("1", from: "c", to: "a")]) == [3, 3, 3])
  }

  @Test("The journal reads a move back as it was saved, and it sends only list_id")
  func roundTrip() async throws {
    let database = try LocalDatabase.inMemory()
    let action = move("7", from: "a", to: "b")
    try await database.record(action, title: "Kettle")
    let (changes, _) = try await database.unsentChangesAndStandIns()
    #expect(changes.map(\.action) == [action])
    #expect(changes.first?.action.targetID == "7")

    let body = try JSONEncoder().encode(ItemChanges(listID: "b"))
    #expect(String(decoding: body, as: UTF8.self) == #"{"list_id":"b"}"#)
  }

  @Test("A refused create takes the move of its item with it")
  func refusedCreate() async throws {
    let database = try LocalDatabase.inMemory()
    let standIn = StandIn.make()
    let created = CreatedItem(
      id: standIn, listID: "a", title: "Kettle", notes: nil, priceMinor: nil, topPriceMinor: nil, currency: nil,
      storeLinks: [], imageIDs: [], addedByID: "me", hidesClaimState: true, createdAt: Date(timeIntervalSince1970: 0))
    try await database.record([
      .init(.createItem(created), title: "Kettle"), .init(move(standIn, from: "a", to: "b"), title: "Kettle"),
    ])
    let create = try #require(try await database.firstUnsentChange())
    try await database.refuse(
      create, refusal: APIError.Refusal(route: .createItem, status: 403, code: .forbidden, detail: ""))
    #expect(try await database.unsentChangeCount() == 0)
    #expect(try await database.lateRefusals().count == 1)
  }

  @Test("A move that can't be read stays in the journal, unsent, and shows nothing")
  func unreadable() async throws {
    let database = try LocalDatabase.inMemory()
    try await database.record(move("7", from: "a", to: "b"), title: "Kettle")
    try await database.change { database in
      try database.execute(sql: "UPDATE unsentChange SET patch = '{\"list_id\": 3}'")
    }
    #expect(try await database.firstUnsentChange() == nil)
    #expect(try await database.unsentChangeCount() == 1)
  }
}
