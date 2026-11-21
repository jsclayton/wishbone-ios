import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// The local copy: what screens read, with or without the instance. See "Offline and keeping in step" in
/// `docs/spec.md`.
@Suite("The local copy", .timeLimit(.minutes(1)))
@MainActor
struct LocalCopyTests {
  let instance: Instance

  init() async throws {
    instance = try await Instance()
  }

  /// Signs a new device in, waits for the titles, and lets the device go, as the app does when it ends.
  private func signInAndQuit(as person: Fixture.Person, storage: SessionStorage, expecting titles: [String])
    async throws
  {
    let device = instance.device(storage: storage)
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    await until { session.primaryListItems.map(\.title) == titles }
  }

  @Test("After a relaunch with the network dropped, the titles still come from the copy")
  func relaunchOffline() async throws {
    let robin = try await instance.person(items: ["Kite", "Puzzle"])
    let folder = try ScratchDirectory("device")
    try await signInAndQuit(as: robin, storage: .folder(folder.url), expecting: ["Kite", "Puzzle"])

    instance.conditioner.dropEverything()
    let relaunched = instance.device(storage: .folder(folder.url))

    // What is saved shows at once, before anything is asked of the instance.
    let session = try #require(relaunched.session)
    #expect(session.primaryListItems.map(\.title) == ["Kite", "Puzzle"])
    #expect(session.user?.name == robin.name)
    #expect(relaunched.signInState == .plain)

    // Unreachable never ends the session, and the copy stays.
    await session.syncNow()
    #expect(session.isInstanceUnreachable)
    #expect(relaunched.session != nil)
    #expect(session.primaryListItems.map(\.title) == ["Kite", "Puzzle"])
  }

  @Test("A sync brings the copy up to date: an item added, an item renamed, and an item removed")
  func syncUpdatesTheCopy() async throws {
    let robin = try await instance.person(items: ["Kite", "Puzzle", "Tent"])
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    let session = try #require(device.session)
    await until { session.primaryListItems.count == 3 }

    let own = try robin.signedIn()
    let puzzle = try #require(session.primaryListItems.first { $0.title == "Puzzle" })
    let tent = try #require(session.primaryListItems.first { $0.title == "Tent" })
    try await own.send("PATCH", "/items/\(puzzle.id)", json: ["title": "Jigsaw"]).expecting(200)
    try await own.send("DELETE", "/items/\(tent.id)").expecting(204)
    _ = try await instance.builder.item("Bike", on: try await instance.builder.primaryList(of: robin), as: robin)

    await session.syncNow()
    await until { session.primaryListItems.map(\.title) == ["Kite", "Jigsaw", "Bike"] }
    #expect(!session.isInstanceUnreachable)
  }

  @Test("Your lists, and a list or a user by ID, come from the copy. What is not in the copy is nil")
  func lookups() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let other = try await instance.person("Sam")
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    let session = try #require(device.session)
    await until { session.primaryList != nil }

    let primary = try #require(session.primaryList)
    #expect(session.yourLists == [primary])
    #expect(session.list(id: primary.id) == primary)
    #expect(session.user(id: robin.id) == session.user)
    #expect(session.user(id: robin.id)?.name == robin.name)

    // A list and a user of the instance that the copy doesn't hold, and an ID that names nothing.
    let hidden = try await instance.builder.primaryList(of: other)
    #expect(session.list(id: hidden.id) == nil)
    #expect(session.user(id: other.id) == nil)
    #expect(session.list(id: "no-such-list") == nil)
  }

  @Test("A list longer than one page comes whole, in the list's order")
  func longList() async throws {
    let titles = (1...(APIClient.pageSize + 1)).map { "Item \($0)" }
    let robin = try await instance.person(items: titles)
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    let session = try #require(device.session)
    await until { session.primaryListItems.count == titles.count }
    #expect(session.primaryListItems.map(\.title) == titles)
  }

  @Test("Each instance and user has a database file of its own, left out of backups")
  func databaseFile() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let folder = try ScratchDirectory("device")
    try await signInAndQuit(as: robin, storage: .folder(folder.url), expecting: ["Kite"])

    let files = FileManager.default
    let sessions = try files.contentsOfDirectory(
      at: folder.url.appending(path: "Sessions"), includingPropertiesForKeys: [.isExcludedFromBackupKey])
    let own = try #require(sessions.first)
    #expect(sessions.count == 1)
    #expect(files.fileExists(atPath: own.appending(path: "database.sqlite").path(percentEncoded: false)))
    #expect(try own.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    // The folder's name gives away neither the instance address nor the user.
    #expect(!own.lastPathComponent.contains("localhost"))
  }

  @Test("A database file that will not open is made again, and the next sync fills the copy")
  func unreadableDatabase() async throws {
    let robin = try await instance.person(items: ["Kite"])
    // The device signs in with its copy in memory, so the session has no database file yet.
    let first = instance.device()
    await first.signIn(pasting: try await instance.loginLink(for: robin))
    let name = try #require(first.session).session.opaqueName

    // Something that is not a database is where the session's database file goes. No connection ever had the
    // file open. A device that has just gone closes its database a moment later, and that close can write the
    // file again.
    let folder = try ScratchDirectory("device")
    let own = folder.url.appending(path: "Sessions").appending(path: name)
    let file = own.appending(path: "database.sqlite")
    let unreadable = Data("not a database".utf8)
    try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
    try unreadable.write(to: file)

    let relaunched = instance.device(storage: .folder(folder.url))
    let session = try #require(relaunched.session)
    #expect(session.primaryListItems.isEmpty)
    // The file is a database again, in the same place.
    #expect(try Data(contentsOf: file).starts(with: Data("SQLite format 3".utf8)))
    await session.syncNow()
    await until { session.primaryListItems.map(\.title) == ["Kite"] }
  }

  @Test("When the database's folder can't be made, the session still works, from a database in memory")
  func noPlaceForTheDatabase() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let folder = try ScratchDirectory("device")
    // A file is where the folder of the databases must go.
    try Data().write(to: folder.url.appending(path: "Sessions"))

    let device = instance.device(storage: .folder(folder.url))
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    let session = try #require(device.session)
    await until { session.primaryListItems.map(\.title) == ["Kite"] }
  }
}
