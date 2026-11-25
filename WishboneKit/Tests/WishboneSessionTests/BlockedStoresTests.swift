import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// Blocked stores, at the session model's seam, against the real server: the admin blocks a store and unblocks it,
/// and each write waits for the server. See "Blocked stores" and "Other writes that wait for the server" in
/// `docs/spec.md`, and `docs/screens/blocked-stores.md`.
///
/// Each test has a server of its own, because the admin's first sync reads every user on the instance: on the shared
/// server it grows with each test of the run, and the admin's sign-in met the suite's time limit on CI. The blocked
/// stores are for the whole instance, so each test still picks out its own, by the builder's tag in their names.
@Suite("Blocked stores", .timeLimit(.minutes(2)))
@MainActor
final class BlockedStoresTests {
  typealias Route = NetworkConditioner.Route

  static let block = Route("POST", "/blocked-stores")
  static let unblock = Route("DELETE", "/blocked-stores/{id}")

  let instance: Instance

  init() async throws {
    instance = try await Instance(server: try await TestServer.start())
  }

  /// A device signed in as the person, with the first sync over. A second person signs in on another instance,
  /// because a device on the same one shares its session keychain, and would be the first person's relaunch.
  ///
  /// For the admin, the session publishes this test's own blocked stores too. The pull reads the blocked stores
  /// last, in a change of their own, and the session publishes each change a moment after it. So the wait for the
  /// user, the first change, is not a wait for them.
  private func signedIn(
    as person: Fixture.Person, on instance: Instance? = nil, diagnostics: RecordingDiagnostics? = nil
  ) async throws -> SessionModel {
    let instance = instance ?? self.instance
    let device = diagnostics.map { instance.device(diagnostics: $0) } ?? instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    await until { session.user?.record != nil }
    if session.isAdmin {
      let own = try await blockedOnServer().filter { $0.contains(self.instance.builder.tag) }.sorted()
      await until { self.ownStores(of: session).sorted() == own }
    }
    return session
  }

  /// The stores that the server blocks, as the admin reads them.
  private func blockedOnServer() async throws -> [String] {
    try await instance.builder.admin.signedIn().all("/blocked-stores").compactMap { $0["store"].string }
  }

  /// A store's host, with this test's tag in it.
  private func store(_ name: String) -> String {
    "\(name)-\(instance.builder.tag).example"
  }

  /// The copy's stores that are this test's own.
  private func ownStores(of session: SessionModel) -> [String] {
    session.blockedStores.map(\.store).filter { $0.contains(instance.builder.tag) }
  }

  @Test("Only the admin is the admin, and only the admin's copy holds blocked stores")
  func onlyTheAdmin() async throws {
    _ = try await instance.builder.blockedStore()
    let admin = try await signedIn(as: instance.builder.admin)
    #expect(admin.isAdmin)
    #expect(!ownStores(of: admin).isEmpty)

    let other = try await Instance()
    let robin = try await signedIn(as: try await other.person("Robin"), on: other)
    #expect(!robin.isAdmin)
    #expect(robin.blockedStores.isEmpty)
    // Someone who is not the admin can't block a store: the server forbids it, and the copy is unchanged.
    guard case .refused(let refusal) = await robin.block(store("nope")) else {
      Issue.record("A block by someone who is not the admin was not refused")
      return
    }
    #expect(refusal.status == 403)
    #expect(robin.blockedStores.isEmpty)
  }

  @Test("The list has the standard family's blocked store, and still shows it with the network dropped")
  func listShowsOffline() async throws {
    let family = try await instance.builder.standardFamily()
    let admin = try await signedIn(as: family.admin)
    let row = try #require(admin.blockedStores.first { $0.id == family.blockedStore.id })
    #expect(row.store == family.blockedStore.store)
    #expect(row.canDelete)

    instance.conditioner.dropEverything()
    await admin.syncNow()
    #expect(admin.isInstanceUnreachable)
    #expect(admin.blockedStores.contains(row))
  }

  @Test(
    "Add blocks the store that a host name or a pasted web address names",
    arguments: [("plain", false), ("pasted", true)])
  func add(name: String, pasted: Bool) async throws {
    let admin = try await signedIn(as: instance.builder.admin)
    let host = store(name)
    let typed = pasted ? "  https://www.\(host)/products/kite?ref=share#top " : " \(host) "

    #expect(await admin.block(typed) == .blocked)

    // The server names the store by its host, and the copy holds what the server answered.
    await until { self.ownStores(of: admin) == [host] }
    #expect(try await blockedOnServer().contains(host))
    let sent = try #require(instance.conditioner.requests.last { $0.isOn(Self.block) })
    #expect(try JSON(parsing: sent.body) == ["store": .string(typed.trimmingCharacters(in: .whitespaces))])
    #expect(sent.headers["idempotency-key"] != nil)

    // A sync keeps it.
    await admin.syncNow()
    #expect(ownStores(of: admin) == [host])
  }

  @Test(
    "A store blocked while a sync runs never leaves the copy, not even for a moment, and one more sync runs after it")
  func blockDuringSync() async throws {
    let admin = try await signedIn(as: instance.builder.admin)
    let host = store("during")

    // The server answers the sync's read of the blocked stores before the block, and the answer arrives after it.
    let held = instance.conditioner.hold(.init("GET", "/blocked-stores"))
    let early = Task { await admin.syncNow() }
    await held.waitUntilHeld()
    let history = CopyHistory(of: admin)
    defer { history.stop() }
    #expect(await admin.block(host) == .blocked)
    await until { self.ownStores(of: admin) == [host] }

    // The answer has no such store, and the block's answer wins over it: that sync keeps the store. The sync after
    // it reads them again, after the block.
    let after = instance.conditioner.hold(.init("GET", "/versions"))
    held.release()
    #expect(await early.value == .succeeded)
    await after.waitUntilHeld()
    #expect(ownStores(of: admin) == [host])
    after.release()

    // A sync after both has ended, so the copy has had every change of them.
    await admin.syncNow()
    await until { self.ownStores(of: admin) == [host] }
    #expect(try await blockedOnServer().contains(host))
    #expect(history.count > 0)
    for (index, stores) in history.blockedStores.enumerated() where !stores.contains(where: { $0.store == host }) {
      Issue.record("The store left the copy at change \(index)")
    }
  }

  @Test("A store unblocked while a sync runs never comes back to the copy, not even for a moment")
  func unblockDuringSync() async throws {
    let blocked = try await instance.builder.blockedStore("undone")
    let admin = try await signedIn(as: instance.builder.admin)
    let row = try #require(admin.blockedStores.first { $0.id == blocked.id })

    // The server answers the sync's read of the blocked stores before the unblock, and the answer arrives after it.
    let held = instance.conditioner.hold(.init("GET", "/blocked-stores"))
    let early = Task { await admin.syncNow() }
    await held.waitUntilHeld()
    #expect(await admin.unblock(row) == .unblocked)
    await until { !admin.blockedStores.contains(row) }
    let history = CopyHistory(of: admin)
    defer { history.stop() }

    // The answer still has the store, and the unblock's answer wins over it: that sync doesn't put it back.
    held.release()
    #expect(await early.value == .succeeded)
    // A sync after both has ended, so the copy has had every change of them.
    await admin.syncNow()
    await until { !admin.blockedStores.contains { $0.id == blocked.id } }
    #expect(!(try await blockedOnServer().contains(blocked.store)))
    for (index, stores) in history.blockedStores.enumerated() where stores.contains(where: { $0.id == blocked.id }) {
      Issue.record("The store came back to the copy at change \(index)")
    }
  }

  @Test("A store that is already blocked is a success, and the list shows it once")
  func alreadyBlocked() async throws {
    let admin = try await signedIn(as: instance.builder.admin)
    let host = store("twice")
    #expect(await admin.block(host) == .blocked)
    #expect(await admin.block("https://\(host)/again") == .blocked)
    await until { self.ownStores(of: admin) == [host] }

    // Blocked elsewhere since the last sync: the copy doesn't have it yet, and after Add it has it once.
    let elsewhere = try await instance.builder.blockedStore("elsewhere")
    #expect(!ownStores(of: admin).contains(elsewhere.store))
    #expect(await admin.block(elsewhere.store) == .blocked)
    await until { admin.blockedStores.contains { $0.id == elsewhere.id } }
    #expect(ownStores(of: admin).filter { $0 == elsewhere.store }.count == 1)
    #expect(admin.blockedStores.filter { $0.id == elsewhere.id }.count == 1)
  }

  @Test("Unblock removes the store from the copy only after the server answers")
  func unblock() async throws {
    let blocked = try await instance.builder.blockedStore("unblock")
    let admin = try await signedIn(as: instance.builder.admin)
    let row = try #require(admin.blockedStores.first { $0.id == blocked.id })

    let hold = instance.conditioner.hold(Self.unblock)
    let unblocking = Task { await admin.unblock(row) }
    await hold.waitUntilHeld()
    // The server has taken it off the list, and its answer is in flight. The copy still holds the store.
    #expect(!(try await blockedOnServer().contains(blocked.store)))
    #expect(admin.blockedStores.contains(row))

    hold.release()
    #expect(await unblocking.value == .unblocked)
    await until { !admin.blockedStores.contains(row) }
    await admin.syncNow()
    #expect(!admin.blockedStores.contains { $0.id == blocked.id })
  }

  @Test("A store that someone else unblocked first is unblocked")
  func unblockedElsewhere() async throws {
    let blocked = try await instance.builder.blockedStore("gone")
    let admin = try await signedIn(as: instance.builder.admin)
    let row = try #require(admin.blockedStores.first { $0.id == blocked.id })
    try await instance.builder.admin.signedIn().send("DELETE", "/blocked-stores/\(blocked.id)").expecting(204)

    #expect(await admin.unblock(row) == .unblocked)
    await until { !admin.blockedStores.contains(row) }
  }

  @Test("With the network dropped, Add and Unblock say the instance can't be reached, and change nothing")
  func offline() async throws {
    let blocked = try await instance.builder.blockedStore("kept")
    let admin = try await signedIn(as: instance.builder.admin)
    let row = try #require(admin.blockedStores.first { $0.id == blocked.id })
    let before = admin.blockedStores

    instance.conditioner.dropEverything()
    #expect(await admin.block(store("offline")) == .unreachable)
    #expect(await admin.unblock(row) == .unreachable)
    #expect(admin.blockedStores == before)

    // Nothing waits to be sent: with the network back, a sync changes nothing on the server.
    instance.conditioner.passEverything()
    await admin.syncNow()
    let onServer = try await blockedOnServer()
    #expect(onServer.contains(blocked.store))
    #expect(!onServer.contains(store("offline")))
    #expect(admin.blockedStores.contains(row))
  }

  @Test(
    "Text that is not a host name or a web address is marked, and nothing is sent",
    arguments: ["", "   ", "kite", "two words.com", "example..com", ".example.com"])
  func notAStore(typed: String) async throws {
    let admin = try await signedIn(as: instance.builder.admin)
    let before = admin.blockedStores
    let mark = instance.conditioner.requests.count

    #expect(await admin.block(typed) == .notAStore)
    #expect(!instance.conditioner.requests.dropFirst(mark).contains { $0.isOn(Self.block) })
    #expect(admin.blockedStores == before)
  }

  @Test("Text that the device lets through and the server refuses is marked, and captured by its code")
  func refusedByTheServer() async throws {
    let diagnostics = RecordingDiagnostics()
    let admin = try await signedIn(as: instance.builder.admin, diagnostics: diagnostics)
    let before = admin.blockedStores
    let mark = instance.conditioner.requests.count

    // The host has a dot, so the device sends it. The server takes off "www." and finds no dot in "example".
    #expect(StoreEntry("www.example") != nil)
    #expect(await admin.block("www.example") == .notAStore)
    #expect(instance.conditioner.requests.dropFirst(mark).filter { $0.isOn(Self.block) }.count == 1)
    #expect(admin.blockedStores == before)
    #expect(diagnostics.faults == [.refusedWrite(.blockStore, code: "invalid_input")])
  }

  @Test("The check of the text takes a host name or a web address, and keeps the text as typed")
  func storeEntry() {
    #expect(StoreEntry("example.com")?.text == "example.com")
    #expect(StoreEntry("  Shop.Example.co.uk\n")?.text == "Shop.Example.co.uk")
    #expect(StoreEntry("https://www.example.com/a/b?c=d")?.text == "https://www.example.com/a/b?c=d")
    #expect(StoreEntry("http://example.com")?.text == "http://example.com")
    #expect(StoreEntry("example.com/kite")?.text == "example.com/kite")
    // As on the server, the dots at the end of the host come off before the checks.
    #expect(StoreEntry("example.com.")?.text == "example.com.")
    #expect(StoreEntry("example.com..")?.text == "example.com..")
    #expect(StoreEntry("https://example.com./p/1")?.text == "https://example.com./p/1")
    // The rest of the server's own list of text that it blocks (`internal/blocklist/blocklist_test.go`).
    for typed in [
      "TEMU.com", "www.temu.com", "https://www.temu.com/p/phone-case?utm_source=x", "http://temu.com:8080/x",
      "https://ｔｅｍｕ.com/p", "xn--bcher-kva.de", "bücher.de", "https://user:pw@temu.com/x", "https://temu.com#top",
    ] {
      #expect(StoreEntry(typed)?.text == typed, "\(typed)")
    }
    for typed in [
      "", "kite", "example.", "ftp://example.com", "https://", "a b.com", "example..com", ".com", "a..com", ".",
    ] {
      #expect(StoreEntry(typed) == nil, "\(typed)")
    }
  }
}
