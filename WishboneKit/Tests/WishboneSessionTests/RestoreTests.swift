import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// I didn't get this, at the session model's seam, against the real server. It waits for the server, then the gift
/// leaves the recipient's Received, and is back in its giver's Giving with the flag that names who said so. See
/// `docs/screens/gift.md`, `docs/screens/gifts.md`, and "Other writes that wait for the server" in `docs/spec.md`.
@Suite("I didn't get this", .timeLimit(.minutes(2)))
@MainActor
final class RestoreTests {
  typealias Route = NetworkConditioner.Route

  static let restore = Route("POST", "/gifts/{id}/restore")

  let instance: Instance

  /// The instances of the devices that the test signed in, kept for the whole test: each one's conditioner is the
  /// way to the server for its device.
  private var others: [Instance] = []

  init() async throws {
    instance = try await Instance()
  }

  /// A device signed in as the person, with the first sync over. A test that drops the network, or cans an answer,
  /// uses this test's own instance: its device goes through that conditioner. Otherwise the person signs in on
  /// another instance of the same server, because a device on the same one shares its session keychain.
  private func signedIn(
    as person: Fixture.Person, on instance: Instance? = nil, diagnostics: RecordingDiagnostics? = nil
  ) async throws -> SessionModel {
    let instance = if let instance { instance } else { try await Instance(server: self.instance.server) }
    others.append(instance)
    let device = diagnostics.map { instance.device(diagnostics: $0) } ?? instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    try await untilInStep(session, as: person)
    return session
  }

  /// The IDs of the gifts in Received, in their order.
  private func received(_ session: SessionModel) -> [String] {
    session.receivedGroups.flatMap { $0.gifts.map(\.id) }
  }

  /// A kite on the child's primary list, that the relative gave the child.
  private func givenKite(in family: StandardFamily, builder: FixtureBuilder) async throws -> Fixture.Gift {
    let list = try await builder.primaryList(of: family.child)
    let kite = try await builder.claim(
      try await builder.item("Kite", on: list, as: family.child), as: family.relative, for: family.groupOccasion)
    try await builder.reveal(giftsFor: family.child)
    return kite
  }

  // MARK: - 1. A restore

  @Test("A restore takes the gift out of Received, and after the giver's sync it is in Giving with its flag")
  func restore() async throws {
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let kite = try await givenKite(in: family, builder: builder)
    let diagnostics = RecordingDiagnostics()
    let child = try await signedIn(as: family.child, diagnostics: diagnostics)
    let giver = try await signedIn(as: family.relative)
    #expect(received(child).contains(kite.id))
    #expect(try #require(child.givenGiftPage(id: kite.id)).restorer == .sessionUser)
    #expect(!giver.giving.map(\.id).contains(kite.id))

    #expect(await child.restore(gift: kite.id) == .restored)

    // The gift left the copy before the restore returned, so every window shows it at once.
    #expect(!received(child).contains(kite.id))
    #expect(child.gift(id: kite.id) == nil)
    #expect(child.givenGiftPage(id: kite.id) == nil)
    #expect(child.unsentChangeCount == 0)
    // The server hides it from the recipient from then on.
    _ = try await family.child.signedIn().send("GET", "/gifts/\(kite.id)").expecting(404)

    // A sync doesn't bring it back.
    #expect(await child.syncNow() == .succeeded)
    try await untilInStep(child, as: family.child)
    #expect(child.gift(id: kite.id) == nil)

    // The giver has it open again, in Giving, with the flag that names the child.
    #expect(await giver.syncNow() == .succeeded)
    try await untilInStep(giver, as: family.relative)
    let group = try #require(giver.givingGroups.first { $0.gifts.contains { $0.id == kite.id } })
    let open = try #require(group.gifts.first { $0.id == kite.id })
    #expect(open.gift.state == .open)
    #expect(open.flags.contains(.restored(by: family.child.name)))
    #expect(!giver.givenGroups.flatMap(\.gifts).map(\.id).contains(kite.id))
    #expect(diagnostics.faults.isEmpty)
  }

  // MARK: - 2. With no connection

  @Test("With the network dropped, I didn't get this changes nothing, and queues nothing")
  func offline() async throws {
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let kite = try await givenKite(in: family, builder: builder)
    let child = try await signedIn(as: family.child, on: instance)
    let before = child.receivedGroups
    #expect(received(child).contains(kite.id))

    instance.conditioner.dropEverything()
    #expect(await child.restore(gift: kite.id) == .unreachable)
    #expect(child.receivedGroups == before)
    #expect(child.unsentChangeCount == 0)

    // Nothing waits to be sent: with the network back, a sync leaves the gift given, in Received.
    instance.conditioner.passEverything()
    #expect(await child.syncNow() == .succeeded)
    try await untilInStep(child, as: family.child)
    #expect(received(child).contains(kite.id))
    let onServer = try await family.relative.signedIn().get("/gifts/\(kite.id)")
    #expect(onServer["state"].string == "given")
    // The dropped restore never reached the instance, and the sync sent none.
    #expect(!instance.conditioner.requests.contains { $0.isOn(Self.restore) })
  }

  // MARK: - 3. A giver who is gone

  @Test("A restore of a gift whose giver is deactivated or deleted takes it out of Received in the same way")
  func giverGone() async throws {
    // A server of this test's own: the canned answer stands for every row of `GET /versions`.
    let instance = try await Instance(server: try await TestServer.start())
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.primaryList(of: family.child)

    // A giver who is then deactivated: the server deletes the gift, and the quantity goes back unclaimed.
    let alex = try await builder.person("Alex")
    _ = try await builder.group("Pair", users: [family.child, alex])
    let kite = try await builder.claim(
      try await builder.item("Kite", on: list, as: family.child), as: alex, for: family.groupOccasion)
    // A giver who is then deleted. The pinned server can't delete a user, so the copy takes the gift as the server
    // sends it then: no giver, and the name they had.
    let book = try await builder.claim(
      try await builder.item("Book", on: list, as: family.child), as: family.relative, for: family.groupOccasion)
    try await builder.reveal(giftsFor: family.child)
    _ = try await builder.deactivate(alex)

    let child = try await signedIn(as: family.child, on: instance)
    try await answer(book, as: family.child, to: child, on: instance) { body in
      body["giver"] = .null
      body["giver_name"] = "Sam"
    }
    instance.conditioner.passEverything()
    #expect(child.gift(id: book.id)?.giverID == nil)
    #expect(Set(received(child)).isSuperset(of: [kite.id, book.id]))

    for gift in [kite, book] {
      let page = try #require(child.givenGiftPage(id: gift.id))
      #expect(page.restorer == .sessionUser)
      #expect(await child.restore(gift: gift.id) == .restored)
      #expect(!received(child).contains(gift.id))
      #expect(child.gift(id: gift.id) == nil)
      _ = try await family.child.signedIn().send("GET", "/gifts/\(gift.id)").expecting(404)
    }
    #expect(await child.syncNow() == .succeeded)
    try await untilInStep(child, as: family.child)
    #expect(!received(child).contains(kite.id))
    #expect(!received(child).contains(book.id))
  }

  // MARK: - 4. Only from can_restore

  @Test("I didn't get this shows only from can_restore, and the gift's giver has none")
  func onlyFromCanRestore() async throws {
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let kite = try await givenKite(in: family, builder: builder)
    let child = try await signedIn(as: family.child)
    let parent = try await signedIn(as: family.parent)
    let giver = try await signedIn(as: family.relative, on: instance)

    // The recipient, and the recipient's parent, for the child.
    let given = try #require(child.gift(id: kite.id))
    #expect(given.canRestore)
    #expect(try #require(child.givenGiftPage(id: kite.id)).restorer == .sessionUser)
    let forChild = try #require(parent.givenGiftPage(id: kite.id))
    #expect(try #require(parent.gift(id: kite.id)).canRestore)
    guard case .child(let named) = forChild.restorer else {
      Issue.record("The parent's page doesn't name the child: \(String(describing: forChild.restorer))")
      return
    }
    #expect(named.id == family.child.id)

    // The giver has none, and a restore of theirs sends nothing.
    let gave = try #require(giver.gift(id: kite.id))
    #expect(!gave.canRestore)
    #expect(try #require(giver.givenGiftPage(id: kite.id)).restorer == nil)
    let mark = instance.conditioner.requests.count
    #expect(await giver.restore(gift: kite.id) == .notOffered)
    #expect(!instance.conditioner.requests.dropFirst(mark).contains { $0.isOn(Self.restore) })

    // An open gift has none either.
    let open = try await builder.claim(
      try await builder.item("Lamp", on: try await builder.primaryList(of: family.child), as: family.child),
      as: family.relative, for: family.groupOccasion)
    #expect(await giver.syncNow() == .succeeded)
    try await untilInStep(giver, as: family.relative)
    #expect(try #require(giver.gift(id: open.id)).canRestore == false)
    #expect(await giver.restore(gift: open.id) == .notOffered)
  }
}
