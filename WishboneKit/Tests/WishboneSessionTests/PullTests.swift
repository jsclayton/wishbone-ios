import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// The pull: a sync asks the instance for the version of everything, compares the answer with the copy, fetches
/// what is new or changed, and removes what is absent. See "When the app syncs" in `docs/spec.md`.
@Suite("A sync pulls what changed, and no more", .timeLimit(.minutes(1)))
@MainActor
struct PullTests {
  typealias Route = NetworkConditioner.Route

  /// The time zone of every device of this suite.
  static let zone = "Europe/Paris"

  let instance: Instance

  /// Each test has a server of its own. On the shared one, a row for the whole instance that another test makes,
  /// such as an occasion for everyone, is one more thing for the pull to fetch.
  init() async throws {
    instance = try await Instance(server: try await TestServer.start())
  }

  /// Signs a new device in, and waits for the titles. The first sync has ended by then.
  ///
  /// The user's record already has the device's time zone. So the sign-in reports none, and nothing changes the
  /// user after the first sync but what the test does.
  private func signedIn(
    as person: Fixture.Person,
    storage: SessionStorage = .memory,
    expecting titles: [String]
  ) async throws -> (device: Device, session: SessionModel) {
    try await person.signedIn().send("PATCH", "/users/me", json: ["timezone": .string(Self.zone)]).expecting(200)
    let device = instance.device(storage: storage, timeZone: .fixed(Self.zone))
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    await until { session.primaryListItems.map(\.title) == titles }
    return (device, session)
  }

  /// How many requests the instance has had. The requests after this mark are those of what the test does next.
  private var mark: Int {
    instance.conditioner.requests.count
  }

  /// What the device asked of the instance after the mark, oldest first.
  private func requests(since mark: Int) -> [NetworkConditioner.SeenRequest] {
    Array(instance.conditioner.requests.dropFirst(mark))
  }

  /// The same requests as text, such as `GET /items/12`: the method, and the path under `/api/v2` with any query.
  private func asked(since mark: Int) -> [String] {
    requests(since: mark).map { "\($0.method) \($0.target.dropFirst(TestServer.apiPrefix.count))" }
  }

  private func item(_ title: String, in session: SessionModel) throws -> ItemRow {
    try #require(session.primaryListItems.first { $0.title == title })
  }

  @Test("A sync after no change is one request, answered 304, and nothing is written")
  func noChange() async throws {
    let robin = try await instance.person(items: ["Kite", "Puzzle"])
    let folder = try ScratchDirectory("device")
    let (_, session) = try await signedIn(as: robin, storage: .folder(folder.url), expecting: ["Kite", "Puzzle"])
    let file = try DatabaseFile(under: folder.url)
    let before = try file.contents
    let mark = self.mark

    await session.sync()

    // One request, with no query: the server refuses any query on this route.
    #expect(asked(since: mark) == ["GET /versions"])
    // It carries the kept ETag, and the server answers that ETag with a 304 for this user.
    let etag = try #require(requests(since: mark).first?.headers["if-none-match"])
    let answer = try await TestHTTP.send(
      "GET", instance.server.url("/versions"),
      headers: ["Authorization": "Bearer \(try robin.signedIn().token)", "If-None-Match": etag])
    #expect(answer.status == 304)
    #expect(try file.contents == before)
    #expect(!session.isInstanceUnreachable)
    #expect(session.primaryListItems.map(\.title) == ["Kite", "Puzzle"])
  }

  @Test("Another session renames an item: the next sync fetches that item only, and the copy has the new title")
  func rename() async throws {
    let robin = try await instance.person(items: ["Kite", "Puzzle", "Tent"])
    let (_, session) = try await signedIn(as: robin, expecting: ["Kite", "Puzzle", "Tent"])
    let puzzle = try item("Puzzle", in: session)
    try await robin.signedIn().send("PATCH", "/items/\(puzzle.id)", json: ["title": "Jigsaw"]).expecting(200)

    var mark = self.mark
    await session.sync()
    #expect(asked(since: mark) == ["GET /versions", "GET /items/\(puzzle.id)"])
    await until { session.primaryListItems.map(\.title) == ["Kite", "Jigsaw", "Tent"] }

    // The copy agrees with that answer, so its ETag is kept, and the next sync is one request again.
    mark = self.mark
    await session.sync()
    #expect(asked(since: mark) == ["GET /versions"])
    #expect(requests(since: mark).first?.headers["if-none-match"] != nil)
  }

  @Test("Another session reorders the list: the next sync asks for the list's items once, not for each item")
  func reorder() async throws {
    let robin = try await instance.person(items: ["Kite", "Puzzle", "Tent"])
    let (_, session) = try await signedIn(as: robin, expecting: ["Kite", "Puzzle", "Tent"])
    let list = try #require(session.primaryList)
    let tent = try item("Tent", in: session)
    // Tent goes to the top, so every item of the list has a new place, and a new version.
    try await robin.signedIn().send("PATCH", "/items/\(tent.id)", json: ["position": 0]).expecting(200)

    let mark = self.mark
    await session.sync()
    #expect(asked(since: mark) == ["GET /versions", "GET /lists/\(list.id)/items?limit=200"])
    await until { session.primaryListItems.map(\.title) == ["Tent", "Kite", "Puzzle"] }
  }

  @Test("An item deleted elsewhere goes from the copy, and one moved off the primary list goes to its new list")
  func deletedAndMoved() async throws {
    let robin = try await instance.person(items: ["Kite", "Puzzle", "Tent"])
    let (_, session) = try await signedIn(as: robin, expecting: ["Kite", "Puzzle", "Tent"])
    let own = try robin.signedIn()
    let camping = try await instance.builder.list("Camping", of: robin)
    try await own.send("PATCH", "/items/\(try item("Tent", in: session).id)", json: ["list_id": .string(camping.id)])
      .expecting(200)
    try await own.send("DELETE", "/items/\(try item("Puzzle", in: session).id)").expecting(204)

    await session.sync()
    await until { session.primaryListItems.map(\.title) == ["Kite"] }
    #expect(session.items(onList: camping.id).map(\.title) == ["Tent"])
    #expect(!session.isInstanceUnreachable)
  }

  @Test(
    """
    Between the versions and the fetch: an item that changes again is saved as the newer one, an item that is \
    deleted is removed, no ETag is kept, and the next sync is a 200 that fetches nothing
    """
  )
  func changesDuringThePull() async throws {
    let robin = try await instance.person(items: ["Kite", "Puzzle"])
    let (_, session) = try await signedIn(as: robin, expecting: ["Kite", "Puzzle"])
    let own = try robin.signedIn()
    let kite = try item("Kite", in: session)
    let puzzle = try item("Puzzle", in: session)
    try await own.send("PATCH", "/items/\(kite.id)", json: ["title": "Box kite"]).expecting(200)
    try await own.send("PATCH", "/items/\(puzzle.id)", json: ["title": "Jigsaw"]).expecting(200)
    _ = try await instance.builder.item("Bike", on: try await instance.builder.primaryList(of: robin), as: robin)

    // The instance has answered with the versions, and the fetch of the items is on its way.
    let hold = instance.conditioner.hold(Route("GET", "/lists/{id}/items"), at: .request)
    var mark = self.mark
    async let syncing: Void = session.sync()
    await hold.waitUntilHeld()
    #expect(asked(since: mark).first == "GET /versions")
    try await own.send("PATCH", "/items/\(kite.id)", json: ["title": "Stunt kite"]).expecting(200)
    try await own.send("DELETE", "/items/\(puzzle.id)").expecting(204)
    hold.release()
    await syncing

    await until { session.primaryListItems.map(\.title) == ["Stunt kite", "Bike"] }
    #expect(!session.isInstanceUnreachable)

    // The fetch gave other versions than the answer named, so that answer's ETag is not kept. The next sync
    // compares again, and the copy already has every version that the instance names.
    mark = self.mark
    await session.sync()
    #expect(asked(since: mark) == ["GET /versions"])
    #expect(requests(since: mark).first?.headers["if-none-match"] == nil)

    // The copy agreed with that answer, so its ETag is kept.
    mark = self.mark
    await session.sync()
    #expect(asked(since: mark) == ["GET /versions"])
    #expect(requests(since: mark).first?.headers["if-none-match"] != nil)
    #expect(session.primaryListItems.map(\.title) == ["Stunt kite", "Bike"])
  }

  @Test("An item that left the list, and is back when the fetch arrives, stays in the copy")
  func backDuringThePull() async throws {
    let robin = try await instance.person(items: ["Kite", "Puzzle", "Tent"])
    let (_, session) = try await signedIn(as: robin, expecting: ["Kite", "Puzzle", "Tent"])
    let own = try robin.signedIn()
    let list = try #require(session.primaryList)
    let tent = try item("Tent", in: session)
    let camping = try await instance.builder.list("Camping", of: robin)
    try await own.send("PATCH", "/items/\(try item("Kite", in: session).id)", json: ["title": "Box kite"])
      .expecting(200)
    try await own.send("PATCH", "/items/\(try item("Puzzle", in: session).id)", json: ["title": "Jigsaw"])
      .expecting(200)
    try await own.send("PATCH", "/items/\(tent.id)", json: ["list_id": .string(camping.id)]).expecting(200)

    // The versions name no Tent on the primary list. It moves back, to the same place, before the items come.
    let hold = instance.conditioner.hold(Route("GET", "/lists/{id}/items"), at: .request)
    async let syncing: Void = session.sync()
    await hold.waitUntilHeld()
    try await own.send("PATCH", "/items/\(tent.id)", json: ["list_id": .string(list.id)]).expecting(200)
    hold.release()
    await syncing

    await until { session.primaryListItems.map(\.title) == ["Box kite", "Jigsaw", "Tent"] }
    #expect(session.primaryListItems.first { $0.id == tent.id }?.version == tent.version)
  }

  @Test(
    """
    Between the versions and an item's own fetch: an item that changes again is saved as the newer one, with its \
    own version, and an item that goes is removed, and the pull goes on
    """
  )
  func changesDuringAnItemsOwnFetch() async throws {
    let robin = try await instance.person(items: ["Kite", "Puzzle"])
    let (_, session) = try await signedIn(as: robin, expecting: ["Kite", "Puzzle"])
    let own = try robin.signedIn()
    let list = try #require(session.primaryList)
    let kite = try item("Kite", in: session)

    // The item changes again while its fetch is on its way.
    try await own.send("PATCH", "/items/\(kite.id)", json: ["title": "Box kite"]).expecting(200)
    var hold = instance.conditioner.hold(Route("GET", "/items/{id}"), at: .request)
    var mark = self.mark
    async let renaming: Void = session.sync()
    await hold.waitUntilHeld()
    try await own.send("PATCH", "/items/\(kite.id)", json: ["title": "Stunt kite"]).expecting(200)
    hold.release()
    await renaming
    await until { session.primaryListItems.map(\.title) == ["Stunt kite", "Puzzle"] }
    #expect(asked(since: mark) == ["GET /versions", "GET /items/\(kite.id)"])

    // The row has the version of its own answer, not the one that the versions named. So no ETag is kept, and
    // the next sync compares again and finds nothing to fetch.
    mark = self.mark
    await session.sync()
    #expect(asked(since: mark) == ["GET /versions"])
    #expect(requests(since: mark).first?.headers["if-none-match"] == nil)

    // The item goes while its fetch is on its way.
    try await own.send("PATCH", "/items/\(kite.id)", json: ["title": "Delta kite"]).expecting(200)
    try await own.send("PATCH", "/lists/\(list.id)", json: ["description": "For the summer"]).expecting(200)
    hold = instance.conditioner.hold(Route("GET", "/items/{id}"), at: .request)
    mark = self.mark
    async let removing: Void = session.sync()
    await hold.waitUntilHeld()
    try await own.send("DELETE", "/items/\(kite.id)").expecting(204)
    hold.release()
    await removing

    // The item's own address answered 404. The row went, and the pull went on to the list.
    await until { session.primaryListItems.map(\.title) == ["Puzzle"] }
    #expect(asked(since: mark) == ["GET /versions", "GET /items/\(kite.id)", "GET /lists/\(list.id)"])
    #expect(!session.isInstanceUnreachable)
  }

  @Test("A first sync that stops between the items and their list publishes neither, and the next sync fills both")
  func stopsBeforeTheList() async throws {
    let robin = try await instance.person(items: ["Kite", "Puzzle"])
    try await robin.signedIn().send("PATCH", "/users/me", json: ["timezone": .string(Self.zone)]).expecting(200)
    let folder = try ScratchDirectory("device")
    do {
      // The items are in the copy when the list's request goes. The network goes before it arrives.
      let device = instance.device(storage: .folder(folder.url), timeZone: .fixed(Self.zone))
      let link = try await instance.loginLink(for: robin)
      let hold = instance.conditioner.hold(Route("GET", "/lists/{id}"), at: .request)
      async let signingIn: Void = device.signIn(pasting: link)
      await hold.waitUntilHeld()
      instance.conditioner.dropEverything()
      hold.release()
      await signingIn
    }

    // The first snapshot comes at once in a new launch, so it shows what the copy holds with no wait.
    let relaunched = instance.device(storage: .folder(folder.url), timeZone: .fixed(Self.zone))
    let session = try #require(relaunched.session)
    #expect(session.user != nil)
    #expect(session.primaryList == nil)
    #expect(session.primaryListItems.isEmpty)

    instance.conditioner.passEverything()
    await session.sync()
    await until { session.primaryListItems.map(\.title) == ["Kite", "Puzzle"] }
    #expect(session.primaryList != nil)
  }

  @Test("An entry of a kind that the app doesn't know is ignored, and the sync succeeds")
  func unknownKind() async throws {
    let robin = try await instance.person(items: ["Kite", "Puzzle"])
    let (_, session) = try await signedIn(as: robin, expecting: ["Kite", "Puzzle"])
    let own = try robin.signedIn()
    let list = try #require(session.primaryList)
    let kite = try item("Kite", in: session)
    let puzzle = try item("Puzzle", in: session)
    try await own.send("PATCH", "/items/\(kite.id)", json: ["title": "Box kite"]).expecting(200)

    // The instance's own answer, with entries of a kind that a later server could add. One has the ID of an
    // item of the copy, and is on the primary list, with another version.
    var entries = try #require(try await own.get("/versions")["data"].array)
    entries.append(["kind": "wish", "id": "1", "version": "\"1\"", "list_id": nil, "item_id": nil])
    entries.append([
      "kind": "wish", "id": .string(puzzle.id), "version": "\"2\"", "list_id": .string(list.id), "item_id": nil,
    ])
    instance.conditioner.answer(
      Route("GET", "/versions"),
      with: .init(
        status: 200, headers: ["Content-Type": "application/json", "ETag": "\"canned\""],
        body: try JSON.object(["data": .array(entries)]).data))

    let mark = self.mark
    await session.sync()
    await until { session.primaryListItems.map(\.title) == ["Box kite", "Puzzle"] }
    #expect(asked(since: mark) == ["GET /versions", "GET /items/\(kite.id)"])
    #expect(!session.isInstanceUnreachable)
  }

  @Test("A sync that fails in the middle keeps what it wrote, and the next sync finishes the job")
  func failsInTheMiddle() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let (_, session) = try await signedIn(as: robin, expecting: ["Kite"])
    let own = try robin.signedIn()
    let kite = try item("Kite", in: session)
    let renamed = instance.builder.name("Robyn")
    try await own.send("PATCH", "/users/\(robin.id)", json: ["name": .string(renamed)]).expecting(200)
    try await own.send("PATCH", "/items/\(kite.id)", json: ["title": "Box kite"]).expecting(200)

    // The user arrives, and then the instance gives no answer for the item.
    instance.conditioner.answer(Route("GET", "/items/{id}"), with: .init(status: 503))
    await session.sync()
    await until { session.user?.name == renamed }
    #expect(session.isInstanceUnreachable)
    #expect(session.primaryListItems.map(\.title) == ["Kite"])

    // The copy agrees with no answer now, so the next sync sends no ETag. It fetches what is left, and not the
    // user again.
    instance.conditioner.passEverything()
    let mark = self.mark
    await session.sync()
    await until { session.primaryListItems.map(\.title) == ["Box kite"] }
    #expect(requests(since: mark).first?.headers["if-none-match"] == nil)
    #expect(asked(since: mark).first == "GET /versions")
    #expect(asked(since: mark).contains("GET /items/\(kite.id)"))
    #expect(!asked(since: mark).contains("GET /users/\(robin.id)"))
    #expect(!session.isInstanceUnreachable)
    #expect(session.user?.name == renamed)
  }

  @Test("A database with an older schema number: the copy is dropped, and the next sync fills it")
  func olderSchemaNumber() async throws {
    let robin = try await instance.person(items: ["Kite", "Puzzle"])
    let folder = try ScratchDirectory("device")
    do {
      // The device goes at the end of this scope, as the app does when it ends.
      _ = try await signedIn(as: robin, storage: .folder(folder.url), expecting: ["Kite", "Puzzle"])
    }
    // The file is as an older version of the app left it: the tables of that version's copy, under its number.
    // The first version of the copy had no number, which is 0.
    try DatabaseFile(under: folder.url).execute("PRAGMA user_version = 0")

    instance.conditioner.dropEverything()
    let relaunched = instance.device(storage: .folder(folder.url), timeZone: .fixed(Self.zone))
    let session = try #require(relaunched.session)
    // The copy is dropped at once, before anything is asked of the instance.
    #expect(session.primaryListItems.isEmpty)
    #expect(session.user == nil)
    #expect(session.primaryList == nil)

    // The kept ETag went with the copy, so the sync fetches everything again.
    instance.conditioner.passEverything()
    let mark = self.mark
    await session.sync()
    await until { session.primaryListItems.map(\.title) == ["Kite", "Puzzle"] }
    #expect(requests(since: mark).first?.headers["if-none-match"] == nil)
    #expect(session.user?.name == robin.name)
  }

  @Test("A 404 for the versions themselves stops the sync, changes nothing, and runs the version check")
  func instanceBelowTheMinimum() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let (device, session) = try await signedIn(as: robin, expecting: ["Kite"])
    let kite = try item("Kite", in: session)
    try await robin.signedIn().send("PATCH", "/items/\(kite.id)", json: ["title": "Box kite"]).expecting(200)

    instance.conditioner.answer(Route("GET", "/versions"), with: try .problem(404, code: "not_found"))
    var mark = self.mark
    await session.sync()
    // The version check finds the instance's version passes: the 404 was something else, and nothing blocks.
    #expect(asked(since: mark) == ["GET /versions", "GET /health"])
    #expect(session.versionBlock == nil)
    #expect(session.primaryListItems.map(\.title) == ["Kite"])
    // The instance answered, so it is not unreachable, and the session stays.
    #expect(!session.isInstanceUnreachable)
    #expect(device.session != nil)

    // The copy still agrees with the answer that it agreed with before, so the next sync sends that ETag.
    instance.conditioner.passEverything()
    mark = self.mark
    await session.sync()
    await until { session.primaryListItems.map(\.title) == ["Box kite"] }
    #expect(requests(since: mark).first?.headers["if-none-match"] != nil)
  }
}
