import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// I won't get this, OK, and Keep it: each an unsent change. See "Unsent changes" and "A page that goes away under a
/// window" in `docs/spec.md`, and "I won't get this", "OK" and "Keep it" in `docs/screens/gift.md`.
@Suite("I won't get this, and the answers to a change", .timeLimit(.minutes(2)))
@MainActor
struct GiftAnswersTests {
  typealias Route = NetworkConditioner.Route

  static let unclaimGift = Route("DELETE", "/gifts/{id}")
  static let acknowledgeGift = Route("POST", "/gifts/{id}/acknowledge")

  let instance: Instance

  /// The one window of the app, as it comes to the foreground.
  let window = UUID()

  init() async throws {
    instance = try await Instance()
  }

  /// A giver with one open gift on an item that one person wants, for an occasion 60 days away, so that no gift is
  /// near its reveal. A third person in the group can claim the item once the gift is gone.
  private struct Seeded {
    let giver: Fixture.Person
    let recipient: Fixture.Person
    let other: Fixture.Person
    let list: Fixture.List
    let occasion: Fixture.Occasion
    let gift: Fixture.Gift
  }

  private func seed() async throws -> Seeded {
    let builder = instance.builder
    let robin = try await builder.person("Robin")
    let morgan = try await builder.person("Morgan")
    let sam = try await builder.person("Sam")
    let family = try await builder.group("Family", users: [robin, morgan, sam])
    let occasion = try await occasion("Spring", inDays: 60, groups: [family])
    // Not the primary list, so that an item can move to another of Morgan's lists.
    let list = try await builder.list("Wishes", of: morgan)
    let kite = try await builder.item("Kite", on: list, as: morgan)
    let gift = try await builder.claim(kite, as: robin, for: occasion)
    return Seeded(giver: robin, recipient: morgan, other: sam, list: list, occasion: occasion, gift: gift)
  }

  /// A shared occasion of the groups, the days from today.
  private func occasion(_ name: String, inDays days: Int, groups: [Fixture.Group]) async throws -> Fixture.Occasion {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let date = try #require(calendar.date(byAdding: .day, value: days, to: .now))
    let month = calendar.component(.month, from: date)
    // An annual occasion on Feb 29 would skip years.
    let day = min(calendar.component(.day, from: date), month == 2 ? 28 : 31)
    return try await instance.builder.sharedOccasion(name, month: month, day: day, groups: groups)
  }

  /// A device of the instance, signed in as the person, with the copy in step.
  private func signedIn(
    as person: Fixture.Person, diagnostics: any DiagnosticsReporter = .none
  ) async throws -> SessionModel {
    let device = instance.device(diagnostics: diagnostics)
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    try await untilInStep(session, as: person)
    return session
  }

  /// The status of the gift for its giver on the server: 200 while they have it, 404 once it is gone.
  private func statusOnServer(_ gift: Fixture.Gift) async throws -> Int {
    try await gift.giver.signedIn().send("GET", "/gifts/\(gift.id)").status
  }

  /// The codes of the gift's flags, as the server has them for its giver.
  private func flagsOnServer(_ gift: Fixture.Gift) async throws -> [String] {
    try await gift.giver.signedIn().get("/gifts/\(gift.id)")["flags"].array?.compactMap { $0["code"].string } ?? []
  }

  private func count(_ route: Route) -> Int {
    instance.conditioner.requests.count { $0.isOn(route) }
  }

  // MARK: - 1. I won't get this

  @Test("I won't get this takes the gift out of Giving at once, and once sent, the item can be claimed again")
  func unclaim() async throws {
    let seeded = try await seed()
    let session = try await signedIn(as: seeded.giver)
    let id = seeded.gift.id
    #expect(session.giving.contains { $0.id == id })
    // The item is fully claimed: no one else can get it.
    let other = try seeded.other.signedIn()
    #expect(try await other.send("POST", "/items/\(seeded.gift.item.id)/gifts", json: ["quantity": 1]).status == 409)

    await session.unclaim(gift: id)
    #expect(!session.giving.contains { $0.id == id })
    #expect(session.gift(id: id) == nil)
    #expect(session.givingGroups.allSatisfy { group in !group.gifts.contains { $0.id == id } })

    await until { session.unsentChangeCount == 0 }
    #expect(count(Self.unclaimGift) == 1)
    #expect(try await statusOnServer(seeded.gift) == 404)
    #expect(session.gift(id: id) == nil)
    #expect(session.lateRefusals.isEmpty)
    // The quantity went back to all givers.
    #expect(try await other.send("POST", "/items/\(seeded.gift.item.id)/gifts", json: ["quantity": 1]).status == 201)
  }

  // MARK: - 2. Offline

  @Test("I won't get this, made with the network dropped, is sent when the instance answers")
  func unclaimOffline() async throws {
    let seeded = try await seed()
    let session = try await signedIn(as: seeded.giver)
    let id = seeded.gift.id

    instance.conditioner.dropEverything()
    await session.unclaim(gift: id)
    #expect(session.gift(id: id) == nil)
    #expect(session.unsentChangeCount == 1)
    await until { session.isInstanceUnreachable }
    // A pull can't bring it back while it waits.
    #expect(try await statusOnServer(seeded.gift) == 200)
    #expect(session.gift(id: id) == nil)

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    #expect(try await statusOnServer(seeded.gift) == 404)
    #expect(session.gift(id: id) == nil)
    #expect(session.lateRefusals.isEmpty)
  }

  // MARK: - 3. A page that goes away under a window

  @Test("A window that shows the gift's page shows the \"not found\" page after I won't get this")
  func pageGoesAway() async throws {
    let seeded = try await seed()
    let session = try await signedIn(as: seeded.giver)
    let id = seeded.gift.id
    // Every window reads the one session model. A window that shows the page reads it from `giftPage(id:)`.
    #expect(session.giftPage(id: id) != nil)

    instance.conditioner.dropEverything()
    await session.unclaim(gift: id)
    // At once, before anything is sent: nil is the "not found" page.
    #expect(session.giftPage(id: id) == nil)

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    #expect(session.giftPage(id: id) == nil)
  }

  // MARK: - 4. Given meanwhile

  @Test("I won't get this for a gift that was given meanwhile is rolled back, and says gift_given")
  func unclaimGiven() async throws {
    let seeded = try await seed()
    let diagnostics = RecordingDiagnostics()
    let session = try await signedIn(as: seeded.giver, diagnostics: diagnostics)
    let id = seeded.gift.id

    instance.conditioner.dropEverything()
    await session.unclaim(gift: id)
    await until { session.isInstanceUnreachable }
    #expect(session.gift(id: id) == nil)
    #expect(try await instance.builder.reveal(giftsFor: seeded.recipient) >= 1)

    instance.conditioner.passEverything()
    await session.syncNow()

    // Rolled back: the journal is empty, and the gift is the server's, given.
    await until { session.unsentChangeCount == 0 }
    await until { session.gift(id: id)?.state == .given }
    #expect(try await statusOnServer(seeded.gift) == 200)
    await until { session.lateRefusals.count == 1 }
    #expect(diagnostics.faults == [.refusedWrite(.unclaimGift, code: "gift_given")])

    await session.cameToForeground(window: window)
    let refusal = try #require(session.lateRefusalAlert?.refusals.first)
    #expect(refusal.action == .unclaim(giftID: id))
    #expect(refusal.title == seeded.gift.item.title)
    #expect(refusal.refusal.code == .giftGiven)
    #expect(refusal.refusal.status == 403)
    #expect(refusal.refusal.route == .unclaimGift)
    session.lateRefusalsShown()
  }

  // MARK: - 5. OK

  @Test("OK clears only its own flag")
  func okClearsOnlyItsFlag() async throws {
    let seeded = try await seed()
    let morgan = try seeded.recipient.signedIn()
    let item = seeded.gift.item.id
    let other = try await instance.builder.list("More wishes", of: seeded.recipient)
    try await morgan.send("PATCH", "/items/\(item)", json: ["title": "Red kite"]).expecting(200)
    try await morgan.send("PATCH", "/items/\(item)", json: ["list_id": .string(other.id)]).expecting(200)
    #expect(try await flagsOnServer(seeded.gift) == ["changed", "moved"])
    let session = try await signedIn(as: seeded.giver)
    let id = seeded.gift.id
    let page = try #require(session.giftPage(id: id))
    #expect(page.flags.count == 2)
    let moved = try #require(page.flags.first { $0.code == "moved" })
    #expect(!moved.isAnsweredByKeepIt)

    instance.conditioner.dropEverything()
    await session.answer(moved, ofGift: id)
    // At once, and only that flag.
    #expect(session.giftPage(id: id)?.flags == [.changed])
    #expect(session.gift(id: id)?.canAcknowledge == true)
    #expect(session.unsentChangeCount == 1)

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    #expect(count(Self.acknowledgeGift) == 1)
    #expect(try await flagsOnServer(seeded.gift) == ["changed"])
    #expect(session.giftPage(id: id)?.flags == [.changed])
    #expect(session.lateRefusals.isEmpty)
  }

  // MARK: - 6. Keep it

  @Test("Keep it clears the removed flag, and the gift stays")
  func keepIt() async throws {
    let seeded = try await seed()
    try await seeded.recipient.signedIn().send("DELETE", "/items/\(seeded.gift.item.id)").expecting(204)
    #expect(try await flagsOnServer(seeded.gift) == ["removed"])
    let session = try await signedIn(as: seeded.giver)
    let id = seeded.gift.id
    let removed = try #require(session.giftPage(id: id)?.flags.first)
    #expect(removed == .removed)
    #expect(removed.isAnsweredByKeepIt)

    await session.answer(removed, ofGift: id)
    #expect(session.giftPage(id: id)?.flags == [])
    #expect(session.giving.contains { $0.id == id })
    await until { session.unsentChangeCount == 0 }

    #expect(try await flagsOnServer(seeded.gift) == [])
    let onServer = try await seeded.giver.signedIn().get("/gifts/\(id)")
    #expect(onServer["state"].string == "open")
    #expect(onServer["can_acknowledge"].bool == false)
    await until { session.gift(id: id)?.canAcknowledge == false }
    #expect(session.giving.contains { $0.id == id })
    #expect(session.giftPage(id: id)?.flags == [])
    #expect(session.lateRefusals.isEmpty)
  }

  // MARK: - 7. The badge

  @Test("The badge falls at once when a changed or a removed flag is answered")
  func badge() async throws {
    let seeded = try await seed()
    let morgan = try seeded.recipient.signedIn()
    let ball = try await instance.builder.item("Ball", on: seeded.list, as: seeded.recipient)
    let second = try await instance.builder.claim(ball, as: seeded.giver, for: seeded.occasion)
    try await morgan.send("PATCH", "/items/\(seeded.gift.item.id)", json: ["title": "Red kite"]).expecting(200)
    try await morgan.send("DELETE", "/items/\(ball.id)").expecting(204)
    let session = try await signedIn(as: seeded.giver)
    #expect(session.giftsBadge == 2)

    // Offline, so the badge falls from the change alone, not from the server's answer.
    instance.conditioner.dropEverything()
    await session.answer(.changed, ofGift: seeded.gift.id)
    #expect(session.giftsBadge == 1)
    await session.answer(.removed, ofGift: second.id)
    #expect(session.giftsBadge == nil)
    #expect(session.gift(id: seeded.gift.id)?.needsAttention == .shown(false))

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    try await untilInStep(session, as: seeded.giver)
    #expect(session.giftsBadge == nil)
  }
}
