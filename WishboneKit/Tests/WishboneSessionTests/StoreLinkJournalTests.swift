import Foundation
import Testing

@testable import WishboneAPI
@testable import WishboneSession

/// What a store link's price edit and its Remove show over the copy before the server answers, and how the journal
/// keeps them. See "Unsent changes" in `docs/spec.md`, and `Journal.swift`. `StoreLinksTests` holds the rest against
/// the real server.
@Suite("A store link's changes over the copy", .timeLimit(.minutes(1)))
struct StoreLinkJournalTests {
  private let read = Date(timeIntervalSince1970: 1_000)
  private let edited = Date(timeIntervalSince1970: 5_000)

  private func link(_ id: String, of itemID: String = "7", at position: Int, priceMinor: Int?, currency: String?)
    -> StoreLinkRow
  {
    StoreLinkRow(
      id: id, itemID: itemID, position: position, url: "https://shop.example/\(id)", store: "shop.example",
      priceMinor: priceMinor, currency: currency, capturedAt: priceMinor == nil ? nil : read, imageURL: nil,
      createdAt: read, canEdit: true, canDelete: true, version: "\"1\"")
  }

  private func change(_ action: UnsentChange.Action, id: Int64 = 1) -> UnsentChange {
    UnsentChange(id: id, action: action, title: "Kite", key: "key")
  }

  private func edit(_ linkID: String, to priceMinor: Int?) -> UnsentChange.Action {
    .editStoreLink(StoreLinkEdit(itemID: "7", storeLinkID: linkID, priceMinor: priceMinor, editedAt: edited))
  }

  @Test("A price edit shows over its link, in the link's currency, read when the user saved it")
  func priceEditShows() throws {
    let rows = [
      link("1", at: 0, priceMinor: 2500, currency: "EUR"), link("2", at: 1, priceMinor: nil, currency: nil),
      link("3", at: 2, priceMinor: 900, currency: "USD"),
    ]
    let shown = LocalDatabase.applying(
      [change(edit("1", to: 1999)), change(edit("2", to: 500), id: 2), change(edit("3", to: nil), id: 3)], to: rows)

    #expect(shown.map(\.id) == ["1", "2", "3"])
    #expect(shown.map(\.priceMinor) == [1999, 500, nil])
    // A link with no price takes USD, as the server does. A cleared price clears its currency, and is read then too.
    #expect(shown.map(\.currency) == ["EUR", "USD", nil])
    #expect(shown.map(\.capturedAt) == [edited, edited, edited])
    #expect(shown.map(\.position) == [0, 1, 2])

    // A link with no price that an edit leaves with none keeps its date, as the server keeps it.
    let none = link("4", at: 3, priceMinor: nil, currency: nil)
    #expect(LocalDatabase.applying([change(edit("4", to: nil))], to: [none]) == [none])
  }

  @Test("A Remove takes its link out, and leaves the others, and a change to a link the copy lacks shows nothing")
  func removeShows() {
    let rows = [link("1", at: 0, priceMinor: 100, currency: "USD"), link("2", at: 1, priceMinor: 200, currency: "USD")]
    let shown = LocalDatabase.applying(
      [
        change(.deleteStoreLink(itemID: "7", storeLinkID: "1")), change(edit("9", to: 1), id: 2),
        change(.deleteStoreLink(itemID: "7", storeLinkID: "9"), id: 3),
      ], to: rows)
    #expect(shown == [rows[1]])
  }

  @Test("The journal reads back a price edit, a cleared price and a Remove as they were saved")
  func roundTrip() async throws {
    let database = try LocalDatabase.inMemory()
    let actions: [UnsentChange.Action] = [
      edit("1", to: 1999), edit("2", to: nil), .deleteStoreLink(itemID: "7", storeLinkID: "3"),
    ]
    try await database.record(actions.map { LocalDatabase.NewChange($0, title: "Kite") })
    let (changes, _) = try await database.unsentChangesAndStandIns()
    #expect(changes.map(\.action) == actions)
    #expect(changes.map(\.action.targetID) == ["1", "2", "3"])
    #expect(try await database.unsentChangeCount() == 3)
  }

  /// A store link as the server's answer gives it.
  private func answered(_ id: String, priceMinor: Int) throws -> Versioned<StoreLink> {
    let body = """
      {"id": "\(id)", "url": "https://shop.example/\(id)", "store": "shop.example", "price_minor": \(priceMinor),
       "currency": "USD", "captured_at": "2026-11-26T10:00:00Z", "image_url": null,
       "created_at": "2026-11-01T10:00:00Z", "can_edit": true, "can_delete": true}
      """
    return Versioned(resource: try JSONDecoder().decode(StoreLink.self, from: Data(body.utf8)), version: "\"2\"")
  }

  @Test("The answer of a price edit takes the place of its link's row, at its place, and a Remove's takes it out")
  func answers() async throws {
    let database = try LocalDatabase.inMemory()
    let rows = [link("1", at: 0, priceMinor: 100, currency: "USD"), link("2", at: 1, priceMinor: 200, currency: "USD")]
    try await database.change { database in
      for row in rows { try row.save(database) }
    }
    try await database.record(edit("2", to: 1999), title: "Kite")
    try await database.record(.deleteStoreLink(itemID: "7", storeLinkID: "1"), title: "Kite")

    let first = try #require(try await database.firstUnsentChange())
    try await database.accept(first, answer: .storeLink(try answered("2", priceMinor: 1999)))
    let second = try #require(try await database.firstUnsentChange())
    try await database.accept(second, answer: .none)

    let saved = try await database.writer.read { try StoreLinkRow.fetchAll($0) }
    #expect(saved.map(\.id) == ["2"])
    #expect(saved.first?.priceMinor == 1999)
    #expect(saved.first?.position == 1)
    #expect(saved.first?.itemID == "7")
    // No body carries a store link's version, so the next pull compares it.
    #expect(saved.first?.version == "")
    #expect(try await database.unsentChangeCount() == 0)
  }

  @Test("A store link's change that can't be read stays in the journal, unsent, and shows nothing")
  func unreadable() async throws {
    let database = try LocalDatabase.inMemory()
    try await database.record(edit("1", to: 1999), title: "Kite")
    try await database.record(.deleteStoreLink(itemID: "7", storeLinkID: "2"), title: "Kite")
    try await database.change { database in
      try database.execute(sql: "UPDATE unsentChange SET patch = '{'")
    }
    #expect(try await database.firstUnsentChange() == nil)
    #expect(try await database.unsentChangeCount() == 2)
  }

  @Test("A store link of an item that waits to be created can't be edited or removed in the sheet")
  func standInLinkIsFixed() {
    let item = ItemRow(
      id: StandIn.make(), listID: "a", title: "Kite", notes: nil, priceMinor: nil, topPriceMinor: nil, currency: nil,
      quantity: 1, isUnlimited: false, position: 0, addedByID: "me", createdAt: read, images: [], primaryImage: nil,
      stillWanted: .hidden, myClaimedQuantity: .hidden, canEdit: true, canDelete: true, canClaim: false,
      canRefreshPrices: false, version: "")
    // As the server would say for the item's links once it has them: the editor can edit and delete each.
    let standIn = link("\(item.id)-link-0", of: item.id, at: 0, priceMinor: 100, currency: nil)
    let saved = link("4", at: 1, priceMinor: 100, currency: nil)
    let draft = ItemEditDraft(item, imageIDs: [], primaryImageID: nil, storeLinks: [standIn, saved])
    #expect(draft.storeLinks.map(\.canEdit) == [false, true])
    #expect(draft.storeLinks.map(\.canDelete) == [false, true])
  }

  @Test("A link's price field is in the link's currency, or in USD for a link with none, whatever the item's")
  func fieldCurrency() {
    let item = ItemRow(
      id: "7", listID: "a", title: "Kite", notes: nil, priceMinor: 1000, topPriceMinor: nil, currency: "EUR",
      quantity: 1, isUnlimited: false, position: 0, addedByID: "me", createdAt: read, images: [], primaryImage: nil,
      stillWanted: .hidden, myClaimedQuantity: .hidden, canEdit: true, canDelete: true, canClaim: false,
      canRefreshPrices: true, version: "")
    let links = [
      link("1", at: 0, priceMinor: 500, currency: "GBP"), link("2", at: 1, priceMinor: nil, currency: nil),
    ]
    var draft = ItemEditDraft(item, imageIDs: [], primaryImageID: nil, storeLinks: links)
    #expect(draft.storeLinks.map(\.currency) == ["GBP", "USD"])
    draft.added(link("3", at: 2, priceMinor: nil, currency: nil))
    #expect(draft.storeLinks.map(\.currency) == ["GBP", "USD", "USD"])
  }

  @Test("When Add link gives an item with no price the link's, the draft takes its currency, and its price if none")
  func itemTookPrice() {
    let item = ItemRow(
      id: "7", listID: "a", title: "Kite", notes: nil, priceMinor: nil, topPriceMinor: nil, currency: nil,
      quantity: 1, isUnlimited: false, position: 0, addedByID: "me", createdAt: read, images: [], primaryImage: nil,
      stillWanted: .hidden, myClaimedQuantity: .hidden, canEdit: true, canDelete: true, canClaim: false,
      canRefreshPrices: true, version: "")
    var untouched = ItemEditDraft(item, imageIDs: [], primaryImageID: nil, storeLinks: [])
    #expect(untouched.currency == "USD")
    var typed = untouched
    typed.priceMinor = 300
    untouched.itemTookPrice(2499, currency: "EUR")
    typed.itemTookPrice(2499, currency: "EUR")
    #expect(untouched.priceMinor == 2499 && untouched.currency == "EUR")
    #expect(typed.priceMinor == 300 && typed.currency == "EUR")
  }
}
