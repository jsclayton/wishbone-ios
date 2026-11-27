import Foundation
import GRDB
import Testing

@testable import WishboneAPI
@testable import WishboneSession

/// What a create of an item shows over the copy before the server answers, and what the journal does with a
/// stand-in ID when an answer comes. See "Unsent changes" in `docs/spec.md`, and `Journal.swift`.
/// `AddByHandOfflineTests` holds the rest against the real server.
@Suite("A create over the copy", .timeLimit(.minutes(1)))
struct CreatedItemTests {
  private func created(_ id: String, on listID: String, imageIDs: [String] = [], hidesClaimState: Bool = true)
    -> CreatedItem
  {
    CreatedItem(
      id: id, listID: listID, title: "Kettle", notes: "Blue", priceMinor: 2500, topPriceMinor: nil, currency: "USD",
      storeLinks: [SearchStoreLink(url: "https://example.com/kettle", store: "example.com")], imageIDs: imageIDs,
      addedByID: "me", hidesClaimState: hidesClaimState, createdAt: Date(timeIntervalSince1970: 0))
  }

  private func change(_ action: UnsentChange.Action, id: Int64 = 1) -> UnsentChange {
    UnsentChange(id: id, action: action, title: "Kettle", key: "key")
  }

  private func item(_ id: String, on listID: String, at position: Int) -> ItemRow {
    ItemRow(
      id: id, listID: listID, title: id, notes: nil, priceMinor: nil, topPriceMinor: nil, currency: nil, quantity: 1,
      isUnlimited: false, position: position, addedByID: "me", createdAt: Date(timeIntervalSince1970: 0), images: [],
      primaryImage: nil, stillWanted: .hidden, myClaimedQuantity: .hidden, canEdit: true, canDelete: true,
      canClaim: false, canRefreshPrices: false, version: "\"1\"")
  }

  @Test("A created item comes after the last item of its list, in the journal's order, and other lists stay")
  func atTheEndOfItsList() {
    let rows = [item("1", on: "a", at: 0), item("2", on: "a", at: 4), item("3", on: "b", at: 0)]
    let first = StandIn.make()
    let second = StandIn.make()
    let shown = LocalDatabase.applying(
      [change(.createItem(created(first, on: "a"))), change(.createItem(created(second, on: "a")), id: 2)],
      to: rows)
    #expect(shown.filter { $0.listID == "a" }.map(\.id) == ["1", "2", first, second])
    #expect(shown.filter { $0.listID == "a" }.map(\.position) == [0, 4, 5, 6])
    #expect(shown.filter { $0.listID == "b" }.map(\.id) == ["3"])
  }

  @Test("A created item shows what the user filled in, one wanted, and no claim state for a recipient")
  func whatItShows() throws {
    let id = StandIn.make()
    let shown = try #require(LocalDatabase.applying([change(.createItem(created(id, on: "a")))], to: [ItemRow]()).first)
    #expect(shown.title == "Kettle" && shown.notes == "Blue" && shown.priceMinor == 2500 && shown.currency == "USD")
    #expect(shown.quantity == 1 && !shown.isUnlimited)
    #expect(shown.addedByID == "me")
    #expect(shown.stillWanted == .hidden && shown.myClaimedQuantity == .hidden)
    #expect(!shown.canClaim && !shown.canRefreshPrices)
    #expect(shown.images.isEmpty && shown.primaryImage == nil)

    // A parent on a child's list sees that nobody has claimed it.
    let forChild = try #require(
      LocalDatabase.applying([change(.createItem(created(id, on: "a", hidesClaimState: false)))], to: [ItemRow]())
        .first)
    #expect(forChild.stillWanted == .shown(1) && forChild.myClaimedQuantity == .shown(0))
  }

  @Test("A created item's store link shows under it, and its list counts it")
  func storeLinkAndCount() {
    let id = StandIn.make()
    let links = LocalDatabase.applying([change(.createItem(created(id, on: "a")))], to: [StoreLinkRow]())
    #expect(links.map(\.itemID) == [id])
    #expect(links.map(\.url) == ["https://example.com/kettle"])
    #expect(links.map(\.store) == ["example.com"])
    let list = ListRow(
      id: "a", name: "Mine", description: nil, isPrimary: true, recipientIDs: ["me"], itemCount: 2,
      createdAt: Date(timeIntervalSince1970: 0), canEdit: true, canDelete: false, canInvite: true, canLeave: false,
      version: "\"1\"")
    #expect(LocalDatabase.applying([change(.createItem(created(id, on: "a")))], to: [list]).map(\.itemCount) == [3])
  }

  @Test("A create sends no image that is still a stand-in: the server refused its upload")
  func sendsNoStandIn() {
    let uploaded = created(StandIn.make(), on: "a", imageIDs: ["31", StandIn.make()])
    #expect(uploaded.newItem.imageIDs == ["31"])
    #expect(uploaded.newItem.storeLinks == [NewStoreLink(url: "https://example.com/kettle")])
  }

  @Test("A create and an upload carry through the journal as they were saved, with their keys and the bytes")
  func carryThroughTheJournal() async throws {
    let database = try LocalDatabase.inMemory()
    let image = StandIn.make()
    let item = created(StandIn.make(), on: "a", imageIDs: [image])
    try await database.record([
      .init(.uploadImage(imageID: image), title: "Kettle", key: "upload-key", file: Data([1, 2, 3])),
      .init(.createItem(item), title: "Kettle", key: "create-key"),
    ])
    let changes = try await database.writer.read { try LocalDatabase.unsentChanges(in: $0) }
    #expect(changes.map(\.action) == [.uploadImage(imageID: image), .createItem(item)])
    #expect(changes.map(\.key) == ["upload-key", "create-key"])
    #expect(try await database.unsentFile(image) == Data([1, 2, 3]))
    // An upload goes with its item: the count is of the items.
    #expect(try await database.snapshot(ofUser: "me").unsentChangeCount == 1)
  }

  @Test(
    """
    An upload's answer puts the server's ID in the place of the stand-in, in the patch and the target of each \
    change that waits, and keeps it. Its bytes leave with it
    """
  )
  func answerReplacesTheStandIn() async throws {
    let database = try LocalDatabase.inMemory()
    let image = StandIn.make()
    let item = created(StandIn.make(), on: "a", imageIDs: [image])
    // No change names an image as what it changes yet: a list edit stands in for one that will.
    try await database.record([
      .init(.uploadImage(imageID: image), title: "Kettle", file: Data([1, 2, 3])),
      .init(.createItem(item), title: "Kettle"),
      .init(.editList(listID: image, changes: ListChanges(name: "New")), title: "Kettle"),
    ])
    let upload = try #require(try await database.firstUnsentChange())
    let answer = try JSONDecoder().decode(
      ImageSummary.self, from: Data(#"{"id":"31","url":"/api/v2/images/31","width":64,"height":48}"#.utf8))

    try await database.accept(upload, answer: .image(answer))

    let changes = try await database.writer.read { try LocalDatabase.unsentChanges(in: $0) }
    guard case .createItem(let sent) = changes.first?.action else {
      Issue.record("The create is not next: \(changes)")
      return
    }
    #expect(sent.id == item.id)
    #expect(sent.imageIDs == ["31"])
    #expect(sent.newItem.imageIDs == ["31"])
    #expect(changes.last?.action == .editList(listID: "31", changes: ListChanges(name: "New")))
    #expect(try await database.unsentFile(image) == nil)
    #expect(try await database.snapshot(ofUser: "me").standIns == [image: "31"])
  }

  @Test("A refused upload leaves with its bytes, and its item's create is sent without it")
  func refusedUpload() async throws {
    let database = try LocalDatabase.inMemory()
    let image = StandIn.make()
    try await database.record([
      .init(.uploadImage(imageID: image), title: "Kettle", file: Data([1, 2, 3])),
      .init(.createItem(created(StandIn.make(), on: "a", imageIDs: [image])), title: "Kettle"),
    ])
    let upload = try #require(try await database.firstUnsentChange())

    try await database.refuse(
      upload, refusal: APIError.Refusal(route: .uploadImage, status: 422, code: .imageInvalid, detail: ""))

    #expect(try await database.unsentFile(image) == nil)
    let refusals = try await database.lateRefusals()
    #expect(refusals.map(\.action) == [.uploadImage(imageID: image)])
    guard case .createItem(let sent) = try await database.firstUnsentChange()?.action else {
      Issue.record("The create is not next")
      return
    }
    #expect(sent.imageIDs == [image])
    #expect(sent.newItem.imageIDs.isEmpty)
  }

  /// The body that a create sends, as JSON to compare.
  private func body(of created: CreatedItem) throws -> NSDictionary {
    try #require(try JSONSerialization.jsonObject(with: try JSONEncoder().encode(created.newItem)) as? NSDictionary)
  }

  private func json(_ text: String) throws -> NSDictionary {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
  }

  /// The patch of the journal's one row.
  private func patch(in database: LocalDatabase) async throws -> String? {
    try await database.change { database in try String.fetchOne(database, sql: "SELECT patch FROM unsentChange") }
  }

  @Test("A create row that an earlier version of the app wrote, with no gift, reads and sends as it did")
  func earlierRow() async throws {
    let database = try LocalDatabase.inMemory()
    let created = created(StandIn.make(), on: "a", imageIDs: ["31"])
    try await database.record(.createItem(created), title: "Kettle")
    // A create filled in by hand writes none of Add again's keys, so its row is the one an earlier version wrote.
    let written = try #require(try await patch(in: database))
    #expect(!written.contains("fromGiftID"))
    #expect(!written.contains("copies"))
    #expect(!written.contains("giftImage"))

    // The patch as an earlier version wrote it, before Add again.
    let earlier = #"""
      {"listID":"a","title":"Kettle","notes":"Blue","priceMinor":2500,"currency":"USD",
      "storeLinks":[{"url":"https://example.com/kettle","store":"example.com"}],"imageIDs":["31"],
      "addedByID":"me","hidesClaimState":true,"createdAt":-978307200}
      """#
    try await database.change { database in
      try database.execute(sql: "UPDATE unsentChange SET patch = ?", arguments: [earlier])
    }
    let change = try #require(try await database.firstUnsentChange())
    #expect(change.action == .createItem(created))
    guard case .createItem(let read) = change.action else { return }
    #expect(read.fromGift == nil)
    #expect(read.giftImage == nil)
    #expect(
      try body(of: read)
        == json(
          #"""
          {"title":"Kettle","notes":"Blue","price_minor":2500,"currency":"USD",
          "store_links":[{"url":"https://example.com/kettle"}],"image_ids":["31"],"primary_image_id":"31"}
          """#))
  }

  @Test("An Add again row keeps the gift, what it copies, and the gift's image, and sends only what changed")
  func addAgainRow() async throws {
    let database = try LocalDatabase.inMemory()
    let image = try JSONDecoder().decode(
      ImageSummary.self, from: Data(#"{"id":"31","url":"/api/v2/images/31","width":4,"height":3}"#.utf8))
    let created = CreatedItem(
      id: StandIn.make(), listID: "a", title: "Kettle", notes: nil, priceMinor: nil, topPriceMinor: nil,
      currency: nil, storeLinks: [], imageIDs: [], addedByID: "me", hidesClaimState: true,
      createdAt: Date(timeIntervalSince1970: 0), fromGift: NewItem.FromGift(giftID: "15", copies: [.title, .image]),
      giftImage: image)
    try await database.record(.createItem(created), title: "Kettle")
    let change = try #require(try await database.firstUnsentChange())
    #expect(change.action == .createItem(created))
    guard case .createItem(let read) = change.action else { return }
    #expect(try body(of: read) == json(#"{"from_gift_id":"15","price_minor":null}"#))
  }

  @Test("A create that can't be read stays in the journal, unsent, and shows nothing")
  func unreadableCreate() async throws {
    let database = try LocalDatabase.inMemory()
    try await database.record(.createItem(created(StandIn.make(), on: "a")), title: "Kettle")
    try await database.change { database in
      try database.execute(sql: "UPDATE unsentChange SET patch = '{'")
    }
    #expect(try await database.firstUnsentChange() == nil)
    #expect(try await database.unsentChangeCount() == 1)
    let snapshot = try await database.snapshot(ofUser: "me")
    #expect(snapshot.items.isEmpty)
  }
}
