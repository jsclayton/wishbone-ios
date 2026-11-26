import Dispatch
import Foundation
import Synchronization
import TestSupport
import Testing
import WishboneAPI

@testable import WishboneSession

/// The copy's observation reads again only the parts of the snapshot that a change touched. These tests hold it to
/// the whole copy: each snapshot that it makes is the copy as its change left it, and the session model gets them
/// in the order of the changes. See `CopyObservation.swift`.
@Suite("The copy's observation", .timeLimit(.minutes(1)))
@MainActor
struct CopyObservationTests {
  let server: TestServer
  let builder: FixtureBuilder

  /// A server of its own, so that the admin's pull reads only what this test makes.
  init() async throws {
    server = try await TestServer.start()
    builder = try await FixtureBuilder(server: server)
  }

  @Test(
    "Each snapshot that a pull's changes give is the whole copy as that change left it, in the order of the changes")
  func pullPublishesInStep() async throws {
    let robin = try await builder.person("Robin")
    let jordan = try await builder.person("Jordan")
    let household = try await builder.group("Household", users: [robin, jordan])
    let reunion = try await builder.sharedOccasion("Reunion", month: 8, day: 1, groups: [household])
    let jordans = try await builder.primaryList(of: jordan)
    let kite = try await builder.item(
      "Kite", on: jordans, as: jordan, storeLinks: [(url: "https://example.com/kite", priceMinor: 1200)])
    let puzzle = try await builder.item("Puzzle", on: jordans, as: jordan)
    _ = try await builder.item("Tent", on: try await builder.primaryList(of: robin), as: robin)
    let camping = try await builder.list("Camping", of: jordan)
    _ = try await builder.item("Lantern", on: camping, as: jordan)
    let invitation = try await builder.invite(robin, to: camping, as: jordan)
    let gift = try await builder.claim(kite, as: robin, for: reunion)

    let folder = try ScratchDirectory("copy")
    let database = try LocalDatabase.open(at: folder.url.appending(path: "database.sqlite"))
    let observed = Observed(database, ofUser: robin.id)
    let pull = Pull(client: try client(for: robin), database: database, userID: robin.id)

    // The first sync: every kind that the user can see arrives, each in changes of its own.
    _ = try await pull.run()
    // A change of each kind, and the next sync: an item comes, an item goes, the user joins a list, and an unsent
    // change shows over its gift.
    _ = try await builder.item("Bunk bed", on: jordans, as: jordan)
    _ = try await jordan.signedIn().send("DELETE", "/items/\(puzzle.id)").expecting(204)
    try await builder.accept(invitation)
    try await database.record(.markBought(giftID: gift.id, isBought: true), title: "Kite")
    _ = try await pull.run()
    // The server refuses the change, and a window shows the refusal.
    let change = try #require(try await database.firstUnsentChange())
    try await database.refuse(
      change, refusal: APIError.Refusal(route: .updateGift, status: 404, code: .notFound, detail: ""))
    try await database.removeLateRefusals(try await database.lateRefusals().map(\.id))

    let made = try await observed.end()
    #expect(made.contains { $0.lists.contains { $0.id == camping.id } && $0.recipients[camping.id]?.count == 2 })
    #expect(
      made.contains { $0.gifts.contains { $0.id == gift.id && $0.isBought.value == true } && $0.unsentChangeCount == 1 }
    )
    #expect(made.contains { $0.lateRefusals.count == 1 })
    let last = try #require(made.last)
    #expect(last.items[jordans.id]?.map(\.title) == ["Kite", "Bunk bed"])
    #expect(last.storeLinks[kite.id]?.map(\.url) == ["https://example.com/kite"])
    #expect(last.invitations.isEmpty && last.lateRefusals.isEmpty && last.unsentChangeCount == 0)
    #expect(Set(last.users.map(\.id)) == [robin.id, jordan.id])
    #expect(last.groups.map(\.id) == [household.id])
    #expect(last.occasions.contains { $0.id == reunion.id })
    #expect(!last.memberships.isEmpty)
  }

  @Test("The admin's blocked stores are in each snapshot as their change left them")
  func blockedStoresInStep() async throws {
    _ = try await builder.blockedStore("blocked-one")
    let folder = try ScratchDirectory("copy")
    let database = try LocalDatabase.open(at: folder.url.appending(path: "database.sqlite"))
    let observed = Observed(database, ofUser: builder.admin.id)
    let pull = Pull(client: try client(for: builder.admin), database: database, userID: builder.admin.id)

    _ = try await pull.run()
    _ = try await builder.blockedStore("blocked-two")
    _ = try await pull.run()

    let made = try await observed.end()
    #expect(made.last?.blockedStores.count == 2)
  }

  @Test("An item that a create adds, and the server's item that takes its place, are in each snapshot in step")
  func createInStep() async throws {
    let robin = try await builder.person("Robin")
    let list = try await builder.primaryList(of: robin)
    let tent = try await builder.item("Tent", on: list, as: robin)
    let folder = try ScratchDirectory("copy")
    let database = try LocalDatabase.open(at: folder.url.appending(path: "database.sqlite"))
    let observed = Observed(database, ofUser: robin.id)
    let client = try client(for: robin)
    let pull = Pull(client: client, database: database, userID: robin.id)
    _ = try await pull.run()

    // An item with a photo, added by hand: the upload, then the create, as the session sends them.
    let bytes = try PhotoAddingTests.image(width: 64, height: 48, as: .png)
    let image = StandIn.make()
    let itemID = StandIn.make()
    let created = CreatedItem(
      id: itemID, listID: list.id, title: "Kettle", notes: nil, priceMinor: nil, topPriceMinor: nil, currency: nil,
      storeLinks: [SearchStoreLink(url: "https://example.com/kettle", store: "example.com")], imageIDs: [image],
      addedByID: robin.id, hidesClaimState: true, createdAt: .now)
    try await database.record([
      .init(.uploadImage(imageID: image), title: "Kettle", file: bytes), .init(.createItem(created), title: "Kettle"),
    ])
    let upload = try #require(try await database.firstUnsentChange())
    let uploaded = try await client.uploadImage(bytes, key: upload.key)
    try await database.accept(upload, answer: .image(uploaded))
    let create = try #require(try await database.firstUnsentChange())
    guard case .createItem(let named) = create.action else {
      Issue.record("The create is not next")
      return
    }
    let item = try await client.createItem(named.newItem, onList: list.id, key: create.key)
    try await database.accept(create, answer: .item(item))
    _ = try await pull.run()

    let made = try await observed.end()
    #expect(
      made.contains { snapshot in
        snapshot.items[list.id]?.map(\.id) == [tent.id, itemID] && snapshot.storeLinks[itemID]?.count == 1
          && snapshot.lists.first { $0.id == list.id }?.itemCount == 2
      })
    let last = try #require(made.last)
    #expect(last.items[list.id]?.map(\.id) == [tent.id, item.resource.id])
    #expect(last.items[list.id]?.last?.primaryImage?.id == uploaded.id)
    #expect(last.storeLinks[item.resource.id]?.map(\.url) == ["https://example.com/kettle"])
    #expect(last.standIns == [image: uploaded.id, itemID: item.resource.id])
    #expect(last.unsentChangeCount == 0)
  }

  /// The API client of the person's own session, straight to the server.
  private func client(for person: Fixture.Person) throws -> APIClient {
    let signedIn = try person.signedIn()
    let instance = try #require(InstanceAddress(server.address.absoluteString))
    return APIClient(
      session: Session(instance: instance, token: signedIn.token, userID: signedIn.userID),
      userAgent: UserAgent(version: "1.0", isPad: false))
  }
}

/// An observation of the copy, as the session model starts it, which keeps what it made and what it gave.
@MainActor
private final class Observed {
  /// Each snapshot that the observation made, and the whole copy read in the same commit.
  private let checked = Checked()

  /// Each snapshot that the observation gave, the first one included.
  private var given: [LocalDatabase.Snapshot] = []
  private var observation: CopyObserver?
  private let database: LocalDatabase
  private let userID: String

  init(_ database: LocalDatabase, ofUser userID: String) {
    self.database = database
    self.userID = userID
    observation = database.observeSnapshots(
      ofUser: userID,
      check: { [checked] made, whole in checked.pairs.withLock { $0.append((made, whole)) } },
      onChange: { [weak self] snapshot in self?.given.append(snapshot) })
  }

  /// Waits for what the observation gave, stops it, and checks it. It returns each snapshot that the observation
  /// made.
  func end(sourceLocation: SourceLocation = #_sourceLocation) async throws -> [LocalDatabase.Snapshot] {
    // The observation gives each snapshot on the main queue, in order. A block put on it now runs after them.
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
    observation?.cancel()
    let checked = checked.pairs.withLock { $0 }
    #expect(!checked.isEmpty, sourceLocation: sourceLocation)
    for (index, pair) in checked.enumerated() where pair.made != pair.whole {
      Issue.record("Snapshot \(index) is not the copy as its change left it.", sourceLocation: sourceLocation)
    }
    // A change that leaves the snapshot as the observation last gave it gives nothing.
    var expected: [LocalDatabase.Snapshot] = []
    var last = LocalDatabase.Snapshot()
    for pair in checked where pair.made != last {
      expected.append(pair.made)
      last = pair.made
    }
    #expect(given.count == expected.count + 1, sourceLocation: sourceLocation)
    #expect(Array(given.dropFirst()) == expected, sourceLocation: sourceLocation)
    #expect(given.last == (try await database.snapshot(ofUser: userID)), sourceLocation: sourceLocation)
    return checked.map(\.made)
  }
}

/// What the observation made, on the writer's queue, for the main actor to read.
private final class Checked: Sendable {
  let pairs = Mutex<[(made: LocalDatabase.Snapshot, whole: LocalDatabase.Snapshot)]>([])
}
