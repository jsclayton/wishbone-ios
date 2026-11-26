import Foundation
import TestSupport
import Testing
import WishboneAPI

@testable import WishboneSession

/// A change that the session records after a create's answer, though it read the copy before: it names the
/// stand-in, which the server's ID has replaced. The journal saves it by the server's ID, as the target and in the
/// patch, so it is never sent to `/items/stand-in-…`. See `StandIn`, and `LocalDatabase.record(_:)`.
///
/// The window is narrow: the answer commits before the copy's observation publishes it. So these tests go through
/// the database's seam, as the session model sends the changes, against the real server.
@Suite("A change recorded after its stand-in was replaced", .timeLimit(.minutes(2)))
@MainActor
struct RecordedStandInTests {
  let server: TestServer
  let builder: FixtureBuilder

  init() async throws {
    server = try await TestServer.shared()
    builder = try await FixtureBuilder(server: server)
  }

  /// The database, after a pull, with an item's upload and create sent and answered, as a sync leaves it.
  private func answered(as person: Fixture.Person) async throws -> (
    database: LocalDatabase, folder: ScratchDirectory, item: (standIn: String, id: String),
    image: (standIn: String, id: String)
  ) {
    let folder = try ScratchDirectory("journal")
    let database = try LocalDatabase.open(at: folder.url.appending(path: "database.sqlite"))
    let signedIn = try person.signedIn()
    let address = try #require(InstanceAddress(server.address.absoluteString))
    let client = APIClient(
      session: Session(instance: address, token: signedIn.token, userID: signedIn.userID),
      userAgent: UserAgent(version: "1.0", isPad: false))
    _ = try await Pull(client: client, database: database, userID: person.id).run()
    let list = try await builder.primaryList(of: person)

    let bytes = try PhotoAddingTests.image(width: 64, height: 48, as: .png)
    let image = StandIn.make()
    let itemID = StandIn.make()
    let created = CreatedItem(
      id: itemID, listID: list.id, title: "Kettle", notes: nil, priceMinor: nil, topPriceMinor: nil, currency: nil,
      storeLinks: [], imageIDs: [], addedByID: person.id, hidesClaimState: true, createdAt: .now)
    try await database.record([
      .init(.uploadImage(imageID: image), title: "Kettle", file: bytes), .init(.createItem(created), title: "Kettle"),
    ])
    let upload = try #require(try await database.firstUnsentChange())
    let uploaded = try await client.uploadImage(bytes, key: upload.key)
    try await database.accept(upload, answer: .image(uploaded))
    let create = try #require(try await database.firstUnsentChange())
    guard case .createItem(let named) = create.action else {
      Issue.record("The create is not next")
      throw CancellationError()
    }
    let item = try await client.createItem(named.newItem, onList: list.id, key: create.key)
    try await database.accept(create, answer: .item(item))
    #expect(try await database.firstUnsentChange() == nil)
    return (database, folder, (itemID, item.resource.id), (image, uploaded.id))
  }

  @Test("A delete that names the item's stand-in is saved by the item's server ID")
  func target() async throws {
    let robin = try await builder.person("Robin")
    let (database, folder, item, _) = try await answered(as: robin)
    defer { withExtendedLifetime(folder) {} }
    let list = try await builder.primaryList(of: robin)

    try await database.record([.init(.deleteItem(itemID: item.standIn, listID: list.id), title: "Kettle")])

    let delete = try #require(try await database.firstUnsentChange())
    #expect(delete.action == .deleteItem(itemID: item.id, listID: list.id))
  }

  @Test("An edit that names a photo's stand-in, in image_ids and as the primary image, is saved by its server ID")
  func patch() async throws {
    let robin = try await builder.person("Robin")
    let (database, folder, item, image) = try await answered(as: robin)
    defer { withExtendedLifetime(folder) {} }

    try await database.record([
      .init(
        .editItem(itemID: item.id, changes: ItemChanges(imageIDs: [image.standIn], primaryImageID: image.standIn)),
        title: "Kettle")
    ])

    let edit = try #require(try await database.firstUnsentChange())
    #expect(
      edit.action == .editItem(itemID: item.id, changes: ItemChanges(imageIDs: [image.id], primaryImageID: image.id)))
  }
}
