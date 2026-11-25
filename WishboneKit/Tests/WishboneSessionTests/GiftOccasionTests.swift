import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// A gift's occasion: the occasions that a giver can pick, worked out from the copy, the pick as an unsent change,
/// a pick that merges two gifts, and Get another for a different occasion, which waits for the server. See "Pick the
/// occasion" and "Get another for a different occasion" in `docs/screens/gift.md`, "Unsent changes" and "Claims are
/// online only" in `docs/spec.md`, and "Occasions for a gift" in the server's spec.
@Suite("A gift's occasion, and Get another for a different occasion", .timeLimit(.minutes(3)))
@MainActor
struct GiftOccasionTests {
  typealias Route = NetworkConditioner.Route

  static let claimRoute = Route("POST", "/items/{id}/gifts")

  /// A giver and a recipient in one group, and a list of the recipient's with a kite on it.
  private struct Seeded {
    let instance: Instance
    let giver: Fixture.Person
    let recipient: Fixture.Person
    let group: Fixture.Group
    let list: Fixture.List
    let kite: Fixture.Item
    let birthday: Fixture.Occasion
  }

  /// Seeds the giver and the recipient. On the shared server unless one is given: a test that reads every
  /// occasion that the giver can pick gives a private one, because every test on the shared server adds an
  /// occasion for everyone.
  private func seed(on server: TestServer? = nil, wanted: Int = 3) async throws -> Seeded {
    let instance = try await Instance(server: server)
    let builder = instance.builder
    let robin = try await builder.person("Robin")
    let morgan = try await builder.person("Morgan")
    let group = try await builder.group("Family", users: [robin, morgan])
    // Not the primary list, which no one else joins.
    let list = try await builder.list("Wishes", of: morgan)
    let kite = try await builder.item("Kite", on: list, as: morgan, quantity: wanted)
    let birthday = try await builder.birthday(of: morgan, as: robin)
    return Seeded(
      instance: instance, giver: robin, recipient: morgan, group: group, list: list, kite: kite, birthday: birthday)
  }

  /// A device of the instance, signed in as the person, with the gifts in its copy.
  private func signedIn(
    as person: Fixture.Person, in instance: Instance, with gifts: [Fixture.Gift],
    diagnostics: any DiagnosticsReporter = .none
  ) async throws -> SessionModel {
    let device = instance.device(diagnostics: diagnostics)
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    await until { gifts.allSatisfy { session.gift(id: $0.id) != nil } }
    return session
  }

  // MARK: - 1. The proof

  @Test("For each giver in the standard family, and each list they see, the copy's occasions are the server's")
  func occasionsFromTheCopy() async throws {
    // A private server: every standard family adds an occasion for everyone, which every user sees.
    let instance = try await Instance(server: try await TestServer.start())
    let builder = instance.builder
    let family = try await builder.standardFamily()
    // One more of each case: a custom occasion to come, one that has passed (no next date), and a list with two
    // recipients whom different givers see.
    _ = try await builder.customOccasion("Recital", of: family.child, year: 2040, month: 6, day: 1)
    _ = try await builder.customOccasion("Graduation", of: family.child, year: 2020, month: 6, day: 1)
    let garage = try await builder.list("Garage", of: family.relative)
    try await builder.accept(try await builder.invite(family.parent, to: garage, as: family.relative))

    var listsWithOccasions = 0
    for giver in [family.parent, family.child, family.relative, family.outsider] {
      let http = try giver.signedIn()
      // The device's zone, so that the sign-in changes nothing that the first sync brought.
      try await http.send("PATCH", "/users/me", json: ["timezone": "UTC"]).expecting(200)
      // Each device needs an instance of its own, with its own keychain.
      let own = try await Instance(server: instance.server)
      let device = own.device()
      await device.signIn(pasting: try await own.loginLink(for: giver))
      let session = try #require(device.session)
      try await untilInStep(session, as: giver)
      // The occasions and their users, which `untilInStep` leaves out.
      let occasionIDs = Set(try await http.all("/occasions").compactMap { $0["id"].string })
      await until {
        Set(session.occasions.map(\.id)) == occasionIDs
          && session.occasions.allSatisfy { session.members(.usersOfOccasion, of: $0.id) != nil }
      }

      for list in session.lists {
        let expected = try await http.all("/occasions?list_id=\(list.id)").compactMap { $0["id"].string }
        let fromCopy = session.pickableOccasions(onList: list.id).map(\.id)
        #expect(fromCopy == expected, "\(giver.name) on \(list.name)")
        if !expected.isEmpty { listsWithOccasions += 1 }
      }
    }
    // The proof proves something: several lists have occasions to pick, and some have none.
    #expect(listsWithOccasions >= 4)
  }

  // MARK: - 2. A pick

  @Test("A pick shows at once, with the reveal date that follows it. After the send, the server has it")
  func pick() async throws {
    let seeded = try await seed()
    let builder = seeded.instance.builder
    let recital = try await builder.customOccasion("Recital", of: seeded.recipient, year: 2040, month: 6, day: 1)
    let gift = try await builder.claim(seeded.kite, as: seeded.giver, for: seeded.birthday)
    let session = try await signedIn(as: seeded.giver, in: seeded.instance, with: [gift])
    await until { session.giftPage(id: gift.id)?.occasions.contains { $0.id == recital.id } == true }
    let page = try #require(session.giftPage(id: gift.id))
    #expect(page.occasions.map(\.id).contains(seeded.birthday.id))

    // Offline, so the pick waits in the journal and shows at once.
    seeded.instance.conditioner.dropEverything()
    #expect(await session.pickOccasion(recital.id, forGift: gift.id) == gift.id)
    let picked = try #require(session.gift(id: gift.id))
    #expect(picked.occasion?.id == recital.id)
    #expect(picked.occasionName == recital.name)
    #expect(picked.occasionDate == "2040-06-01")
    // The recipient has no time zone: the reveal is midnight in UTC, at the start of the day after.
    #expect(picked.revealAt == ISO8601DateFormatter().date(from: "2040-06-02T00:00:00Z"))
    #expect(session.giftPage(id: gift.id)?.occasion == .named(recital.name))
    #expect(session.giving.first { $0.id == gift.id }?.occasion?.id == recital.id)
    #expect(session.unsentChangeCount == 1)
    // The same occasion again is no change.
    #expect(await session.pickOccasion(recital.id, forGift: gift.id) == nil)
    #expect(session.unsentChangeCount == 1)

    seeded.instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    let server = try await seeded.giver.signedIn().get("/gifts/\(gift.id)")
    #expect(server["occasion"]["id"].string == recital.id)
    #expect(server["reveal_at"].string.flatMap { ISO8601DateFormatter().date(from: $0) } == picked.revealAt)
    let body = try #require(
      seeded.instance.conditioner.requests.last { $0.isOn(Route("PATCH", "/gifts/{id}")) }?.body)
    #expect((try JSONSerialization.jsonObject(with: body) as? [String: String]) == ["occasion_id": recital.id])
    #expect(session.lateRefusals.isEmpty)
  }

  // MARK: - 3. A pick that merges

  @Test("A pick that merges: the gift that stays has both, Giving has one gift, and the other is not found")
  func merge() async throws {
    let seeded = try await seed(wanted: 5)
    let builder = seeded.instance.builder
    let recital = try await builder.customOccasion("Recital", of: seeded.recipient, year: 2040, month: 6, day: 1)
    let moving = try await builder.claim(seeded.kite, as: seeded.giver, for: seeded.birthday, note: "The red one")
    let staying = try await builder.claim(
      seeded.kite, as: seeded.giver, for: recital, quantity: 2, fromLabel: "Emma", note: "Wrap it")
    let session = try await signedIn(as: seeded.giver, in: seeded.instance, with: [moving, staying])
    await until { session.giftPage(id: moving.id)?.occasions.contains { $0.id == recital.id } == true }

    // The page that showed the moving gift follows the pick to the gift that stays.
    #expect(session.gift(holdingPick: recital.id, of: moving.id) == staying.id)
    seeded.instance.conditioner.dropEverything()
    #expect(await session.pickOccasion(recital.id, forGift: moving.id) == staying.id)

    // At once: one gift on the item, with both quantities and both notes, and the moving gift is gone.
    #expect(session.giftPage(id: moving.id) == nil)
    let merged = try #require(session.giftPage(id: staying.id)?.gift)
    #expect(merged.quantity == 3)
    #expect(merged.fromLabel == "Emma")
    #expect(merged.note == .shown("Wrap it\nThe red one"))
    #expect(session.giving.filter { $0.itemID == seeded.kite.id }.map(\.id) == [staying.id])

    // After the send, the server agrees, and the moving gift's address is a 404.
    seeded.instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    let http = try seeded.giver.signedIn()
    let server = try await http.get("/gifts/\(staying.id)")
    #expect(server["quantity"].number == 3)
    #expect(server["note"].string == "Wrap it\nThe red one")
    #expect(try await http.status(of: "/gifts/\(moving.id)") == 404)
    #expect(session.gift(id: moving.id) == nil)
    #expect(session.giving.filter { $0.itemID == seeded.kite.id }.map(\.quantity) == [3])
    #expect(session.lateRefusals.isEmpty)
  }

  // MARK: - 4. Locked

  @Test("When the giver can see none of the other recipients, the occasion can't be picked, as the server says")
  func locked() async throws {
    let seeded = try await seed()
    let builder = seeded.instance.builder
    let gift = try await builder.claim(seeded.kite, as: seeded.giver, for: seeded.birthday)
    let session = try await signedIn(as: seeded.giver, in: seeded.instance, with: [gift])
    #expect(session.canPickOccasion(ofGift: gift.id))
    #expect(session.giftPage(id: gift.id)?.occasions.isEmpty == false)

    // The recipient leaves the one group that they share with the giver: the giver sees no one on the list.
    try await builder.admin.signedIn().send("DELETE", "/groups/\(seeded.group.id)/users/\(seeded.recipient.id)")
      .expecting(204)
    await session.syncNow()
    await until { session.list(id: seeded.list.id) == nil && session.gift(id: gift.id) != nil }

    #expect(!session.canPickOccasion(ofGift: gift.id))
    #expect(session.giftPage(id: gift.id)?.occasions == [])
    #expect(session.giftPage(id: gift.id)?.anotherOccasion == nil)
    #expect(await session.pickOccasion(seeded.birthday.id, forGift: gift.id) == nil)
    #expect(session.unsentChangeCount == 0)
    // The server agrees: any occasion is 422 occasion_locked.
    let answer = try await seeded.giver.signedIn().send(
      "PATCH", "/gifts/\(gift.id)", json: ["occasion_id": .string(seeded.birthday.id)])
    #expect(answer.status == 422)
    #expect(try answer.json["code"].string == "occasion_locked")
  }

  // MARK: - 5. A late refusal

  @Test("A late occasion_not_allowed rolls the pick back, waits to show, and is captured as a write's 422")
  func lateRefusal() async throws {
    let seeded = try await seed()
    let builder = seeded.instance.builder
    let recital = try await builder.customOccasion("Recital", of: seeded.recipient, year: 2040, month: 6, day: 1)
    let gift = try await builder.claim(seeded.kite, as: seeded.giver, for: seeded.birthday)
    let diagnostics = RecordingDiagnostics()
    let session = try await signedIn(
      as: seeded.giver, in: seeded.instance, with: [gift], diagnostics: diagnostics)
    await until { session.giftPage(id: gift.id)?.occasions.contains { $0.id == recital.id } == true }
    let before = try #require(session.gift(id: gift.id))

    seeded.instance.conditioner.dropEverything()
    await session.pickOccasion(recital.id, forGift: gift.id)
    #expect(session.gift(id: gift.id)?.occasion?.id == recital.id)
    await until { session.isInstanceUnreachable }
    // Meanwhile, the recipient deletes the occasion.
    try await seeded.recipient.signedIn().send("DELETE", "/occasions/\(recital.id)").expecting(204)

    seeded.instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 && session.lateRefusals.count == 1 }
    await until { session.gift(id: gift.id)?.occasion?.id == seeded.birthday.id }
    #expect(session.gift(id: gift.id)?.revealAt == before.revealAt)
    let refusal = try #require(session.lateRefusals.first)
    #expect(refusal.refusal.code == .occasionNotAllowed)
    #expect(refusal.refusal.status == 422)
    #expect(refusal.title == seeded.kite.title)
    guard case .setOccasion(let id, let occasion) = refusal.action else {
      Issue.record("The late refusal is of \(refusal.action)")
      return
    }
    #expect(id == gift.id)
    #expect(occasion.id == recital.id)
    #expect(diagnostics.faults == [.refusedWrite(.updateGift, code: "occasion_not_allowed")])
  }

  // MARK: - 6. When Get another shows

  @Test("Get another shows only while the item can be claimed and an occasion that the giver can pick is free")
  func getAnotherShows() async throws {
    // A private server: no occasion for everyone from another test is free.
    let seeded = try await seed(on: try await TestServer.start(), wanted: 3)
    let builder = seeded.instance.builder
    let ball = try await builder.item("Ball", on: seeded.list, as: seeded.recipient, quantity: 1)
    let kiteGift = try await builder.claim(seeded.kite, as: seeded.giver, for: seeded.birthday)
    let ballGift = try await builder.claim(ball, as: seeded.giver, for: seeded.birthday)
    let session = try await signedIn(as: seeded.giver, in: seeded.instance, with: [kiteGift, ballGift])
    await until { session.item(id: seeded.kite.id) != nil }

    // The birthday is the only occasion, and the giver has a gift for it.
    #expect(session.pickableOccasions(onList: seeded.list.id).map(\.id) == [seeded.birthday.id])
    #expect(session.anotherOccasion(forGift: kiteGift.id) == nil)
    #expect(session.giftPage(id: kiteGift.id)?.anotherOccasion == nil)
    #expect(await session.getAnother(forGift: kiteGift.id) == .notOffered)

    // Another occasion comes: Get another shows on the kite, which can still be claimed, and not on the ball, which
    // can't.
    let recital = try await builder.customOccasion("Recital", of: seeded.recipient, year: 2040, month: 6, day: 1)
    await session.syncNow()
    await until { session.anotherOccasion(forGift: kiteGift.id)?.id == recital.id }
    #expect(session.giftPage(id: kiteGift.id)?.anotherOccasion?.id == recital.id)
    #expect(session.item(id: ball.id)?.canClaim == false)
    #expect(session.anotherOccasion(forGift: ballGift.id) == nil)
    #expect(await session.getAnother(forGift: ballGift.id) == .notOffered)
    #expect(seeded.instance.conditioner.requests.filter { $0.isOn(Self.claimRoute) }.isEmpty)
  }

  // MARK: - 7. Get another

  @Test("Get another claims for the soonest free occasion after the server answers, and gives the new gift")
  func getAnother() async throws {
    let seeded = try await seed(on: try await TestServer.start(), wanted: 3)
    let builder = seeded.instance.builder
    _ = try await builder.customOccasion("Recital", of: seeded.recipient, year: 2040, month: 6, day: 1)
    let graduation = try await builder.customOccasion(
      "Graduation", of: seeded.recipient, year: 2039, month: 1, day: 1)
    let gift = try await builder.claim(seeded.kite, as: seeded.giver, for: seeded.birthday)
    let session = try await signedIn(as: seeded.giver, in: seeded.instance, with: [gift])
    await until { session.anotherOccasion(forGift: gift.id)?.id == graduation.id }

    let answer = seeded.instance.conditioner.hold(Self.claimRoute)
    let claim = Task { await session.getAnother(forGift: gift.id) }
    await answer.waitUntilHeld()
    // The answer is held: no new gift, and nothing waits in the journal.
    #expect(session.giving.filter { $0.itemID == seeded.kite.id }.count == 1)
    #expect(session.unsentChangeCount == 0)
    answer.release()
    guard case .claimed(let id) = await claim.value else {
      Issue.record("Get another didn't claim")
      return
    }
    #expect(id != gift.id)
    let made = try #require(session.giftPage(id: id))
    #expect(made.gift.occasion?.id == graduation.id)
    #expect(made.gift.quantity == 1)
    #expect(session.giving.filter { $0.itemID == seeded.kite.id }.count == 2)
    let server = try await seeded.giver.signedIn().get("/gifts/\(id)")
    #expect(server["occasion"]["id"].string == graduation.id)
    let body = try #require(seeded.instance.conditioner.requests.last { $0.isOn(Self.claimRoute) }?.body)
    #expect(
      (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["occasion_id"] as? String == graduation.id)
  }

  // MARK: - 8. With no connection

  @Test("Get another with the network dropped claims nothing, and queues nothing")
  func getAnotherOffline() async throws {
    let seeded = try await seed(on: try await TestServer.start(), wanted: 3)
    let builder = seeded.instance.builder
    _ = try await builder.customOccasion("Recital", of: seeded.recipient, year: 2040, month: 6, day: 1)
    let gift = try await builder.claim(seeded.kite, as: seeded.giver, for: seeded.birthday)
    let session = try await signedIn(as: seeded.giver, in: seeded.instance, with: [gift])
    await until { session.anotherOccasion(forGift: gift.id) != nil }

    seeded.instance.conditioner.dropEverything()
    #expect(await session.getAnother(forGift: gift.id) == .notClaimed(.unreachable))
    #expect(session.giving.filter { $0.itemID == seeded.kite.id }.map(\.id) == [gift.id])
    #expect(session.unsentChangeCount == 0)

    seeded.instance.conditioner.passEverything()
    await session.syncNow()
    let onServer = try await seeded.giver.signedIn().all("/gifts?item_id=\(seeded.kite.id)")
    #expect(onServer.compactMap { $0["id"].string } == [gift.id])
    await until { session.unsentChangeCount == 0 }
    #expect(session.giving.filter { $0.itemID == seeded.kite.id }.map(\.id) == [gift.id])
  }
}
