import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// Giving and the Gifts tab's badge: the giver's open gifts in groups by list and occasion, the groups that need
/// attention first, each flag with what its words need, and the badge as the server counts it. See
/// `docs/screens/gifts.md`, and "Home" in `docs/spec.md`.
@Suite("Giving and the Gifts tab's badge", .timeLimit(.minutes(2)))
@MainActor
struct GivingTests {
  typealias Route = NetworkConditioner.Route

  /// A device of the instance, signed in as the person. Its first sync has ended, and the session has published
  /// what the instance names for the person.
  private func signedIn(as person: Fixture.Person, on instance: Instance) async throws -> SessionModel {
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    try await untilInStep(session, as: person)
    return session
  }

  /// A shared occasion of the family, the days from today, so that every gift for it is far from its reveal and
  /// needs attention only for a flag.
  private func occasion(
    _ name: String, inDays days: Int, of family: StandardFamily, builder: FixtureBuilder
  ) async throws -> Fixture.Occasion {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let date = try #require(calendar.date(byAdding: .day, value: days, to: .now))
    let month = calendar.component(.month, from: date)
    // An annual occasion on Feb 29 would skip years.
    let day = min(calendar.component(.day, from: date), month == 2 ? 28 : 31)
    return try await builder.sharedOccasion(name, month: month, day: day, groups: [family.family])
  }

  /// What `seedGiving` made: the relative's open gifts on the child's list and the parent's list.
  private struct Seeded {
    let family: StandardFamily
    let spring: Fixture.Occasion
    let summer: Fixture.Occasion
    let kite: Fixture.Gift
    let book: Fixture.Gift
    let scarf: Fixture.Gift

    /// For summer on the parent's list. It needs no attention, so its group comes after the spring groups.
    let gloves: Fixture.Gift

    /// The child changed the lamp after the relative claimed it, so it needs attention.
    let lamp: Fixture.Gift
  }

  /// The relative gives the child a kite and a book for spring and a lamp for summer, and gives the parent a scarf
  /// for spring and gloves for summer. The child then changes the lamp.
  private func seedGiving(on instance: Instance) async throws -> Seeded {
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let spring = try await occasion("Spring", inDays: 60, of: family, builder: builder)
    let summer = try await occasion("Summer", inDays: 120, of: family, builder: builder)
    let childsList = try await builder.primaryList(of: family.child)
    let parentsList = try await builder.primaryList(of: family.parent)
    let kite = try await builder.claim(
      try await builder.item("Kite", on: childsList, as: family.child), as: family.relative, for: spring)
    let book = try await builder.claim(
      try await builder.item("Book", on: childsList, as: family.child), as: family.relative, for: spring)
    let lampItem = try await builder.item("Lamp", on: childsList, as: family.child)
    let lamp = try await builder.claim(lampItem, as: family.relative, for: summer)
    let scarf = try await builder.claim(
      try await builder.item("Scarf", on: parentsList, as: family.parent), as: family.relative, for: spring)
    let gloves = try await builder.claim(
      try await builder.item("Gloves", on: parentsList, as: family.parent), as: family.relative, for: summer)
    try await family.child.signedIn().send("PATCH", "/items/\(lampItem.id)", json: ["title": "Red lamp"])
      .expecting(200)
    return Seeded(
      family: family, spring: spring, summer: summer, kite: kite, book: book, scarf: scarf, gloves: gloves, lamp: lamp)
  }

  /// The group that holds the gift.
  private func group(of gift: Fixture.Gift, in groups: [GivingGroup]) throws -> GivingGroup {
    try #require(groups.first { $0.gifts.contains { $0.id == gift.id } })
  }

  /// Answers the device's next pull with the gift as the instance sends it, edited: `GET /versions` names it with
  /// a new version, and `GET /gifts/{id}` gives the edited body. Returns when the copy holds it.
  private func answer(
    _ gift: Fixture.Gift, as person: Fixture.Person, to session: SessionModel, on instance: Instance,
    edited edit: (inout [String: JSON]) -> Void
  ) async throws {
    guard case .object(var body) = try await person.signedIn().get("/gifts/\(gift.id)") else {
      Issue.record("The gift is not an object")
      return
    }
    edit(&body)
    // A new version for each answer, so the pull fetches the gift again.
    let version = "\"canned-\(UUID().uuidString)\""
    var entries = try #require(try await person.signedIn().get("/versions")["data"].array)
    entries = entries.map { entry in
      guard entry["kind"] == "gift", entry["id"].string == gift.id else { return entry }
      return ["kind": "gift", "id": entry["id"], "version": .string(version), "list_id": nil, "item_id": nil]
    }
    instance.conditioner.answer(
      Route("GET", "/versions"),
      with: .init(
        status: 200, headers: ["Content-Type": "application/json", "ETag": "\"canned\""],
        body: try JSON.object(["data": .array(entries)]).data))
    instance.conditioner.answer(
      Route("GET", "/gifts/\(gift.id)"),
      with: .init(
        status: 200, headers: ["Content-Type": "application/json", "ETag": version],
        body: try JSON.object(body).data))
    await session.syncNow()
    await until { session.gift(id: gift.id)?.version == version }
  }

  // MARK: - 1. Groups

  @Test("The gifts group by list and occasion, and a group names its recipients and its occasion")
  func groups() async throws {
    let instance = try await Instance()
    let seeded = try await seedGiving(on: instance)
    let family = seeded.family
    let session = try await signedIn(as: family.relative, on: instance)
    let groups = session.givingGroups

    // The child's spring gifts are one group: one list, one occasion.
    let childsSpring = try group(of: seeded.kite, in: groups)
    #expect(Set(childsSpring.gifts.map(\.id)) == [seeded.kite.id, seeded.book.id])
    #expect(childsSpring.recipients?.map(\.name) == [family.child.name])
    #expect(childsSpring.occasion == .named(seeded.spring.name))

    // The same list for another occasion is a group of its own, and so is another list for the same occasion.
    let childsSummer = try group(of: seeded.lamp, in: groups)
    #expect(childsSummer.gifts.map(\.id) == [seeded.lamp.id])
    #expect(childsSummer.recipients?.map(\.name) == [family.child.name])
    #expect(childsSummer.occasion == .named(seeded.summer.name))
    let parentsSpring = try group(of: seeded.scarf, in: groups)
    #expect(parentsSpring.gifts.map(\.id) == [seeded.scarf.id])
    #expect(parentsSpring.recipients?.map(\.name) == [family.parent.name])
    #expect(parentsSpring.occasion == .named(seeded.spring.name))

    // Every open gift is in one group, once: Giving is the server's `?giver_id=me&state=open`.
    let ids = groups.flatMap { $0.gifts.map(\.id) }
    #expect(ids.count == Set(ids).count)
    #expect(Set(ids) == Set(session.giving.map(\.id)))
    #expect(Set(groups.map(\.id)).count == groups.count)
  }

  // MARK: - 2. Order, and 5. the badge

  @Test(
    """
    A group that needs attention is first, then the groups are in order of reveal, and the badge equals the \
    server's count of open gifts that need attention
    """
  )
  func order() async throws {
    let instance = try await Instance()
    let seeded = try await seedGiving(on: instance)
    let session = try await signedIn(as: seeded.family.relative, on: instance)
    let groups = session.givingGroups

    // The lamp's group is later than spring's, and it goes first because the lamp changed.
    let first = try #require(groups.first)
    #expect(first.gifts.map(\.id) == [seeded.lamp.id])
    #expect(first.needsAttention)
    #expect(first.gifts.first?.needsAttention == true)
    #expect(first.gifts.first?.flags == [.changed])
    let rest = Array(groups.dropFirst())
    #expect(rest.allSatisfy { !$0.needsAttention })

    // Then the rest in order of reveal: the two spring groups, then the parent's summer group. The spring groups
    // reveal on one day, so the server's order breaks the tie: the soonest reveal, then the gift's ID.
    let childsSpring = try group(of: seeded.kite, in: groups)
    let parentsSpring = try group(of: seeded.scarf, in: groups)
    let parentsSummer = try group(of: seeded.gloves, in: groups)
    let spring = [childsSpring, parentsSpring].sorted { $0.gifts[0].id < $1.gifts[0].id }
    #expect(rest.map(\.id) == spring.map(\.id) + [parentsSummer.id])
    let springReveal = try #require(childsSpring.gifts.first?.gift.revealAt)
    #expect(parentsSpring.gifts.allSatisfy { $0.gift.revealAt == springReveal })
    #expect(parentsSummer.gifts.allSatisfy { $0.gift.revealAt > springReveal })
    for group in groups {
      let inGroup = group.gifts.map(\.gift.revealAt)
      #expect(inGroup == inGroup.sorted())
    }

    // The badge is the server's count.
    let needing = try await seeded.family.relative.signedIn().all("/gifts?giver_id=me&state=open&needs_attention=true")
    #expect(needing.map { $0["id"].string } == [seeded.lamp.id])
    #expect(session.giftsBadge == needing.count)
  }

  // MARK: - 3. What the giver can't see

  @Test(
    """
    A gift whose occasion the giver can't see has only its reveal date, and a gift whose list the giver can't see \
    has no recipients
    """
  )
  func hidden() async throws {
    let instance = try await Instance(server: try await TestServer.start())
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.primaryList(of: family.child)
    let kite = try await builder.claim(
      try await builder.item("Kite", on: list, as: family.child), as: family.relative, for: family.groupOccasion)
    let session = try await signedIn(as: family.relative, on: instance)

    // The occasion is hidden: the server sends no occasion, and no name.
    try await answer(kite, as: family.relative, to: session, on: instance) { body in
      body["occasion"] = .null
      body["occasion_name"] = .null
    }
    let revealAt = try #require(session.gift(id: kite.id)?.revealAt)
    var group = try self.group(of: kite, in: session.givingGroups)
    #expect(group.occasion == .hiddenUntil(revealAt))
    #expect(group.recipients?.map(\.name) == [family.child.name])

    // The list is hidden too: the server sends no `recipients`.
    try await answer(kite, as: family.relative, to: session, on: instance) { body in
      body["occasion"] = .null
      body["occasion_name"] = .null
      body.removeValue(forKey: "recipients")
    }
    group = try self.group(of: kite, in: session.givingGroups)
    #expect(group.recipients == nil)
    #expect(group.occasion == .hiddenUntil(revealAt))
  }

  // MARK: - 4. Flags

  @Test("Each flag gives what its words need, and a flag code that the app doesn't know breaks nothing")
  func flags() async throws {
    let instance = try await Instance(server: try await TestServer.start())
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.primaryList(of: family.child)
    let toys = try await builder.list("Toys", of: family.child)
    let kite = try await builder.claim(
      try await builder.item("Kite", on: list, as: family.child), as: family.relative, for: family.groupOccasion)
    let session = try await signedIn(as: family.relative, on: instance)

    let robin: JSON = ["id": .string(family.child.id), "name": .string(family.child.name), "avatar": nil]
    let morgan: JSON = ["id": .string(family.parent.id), "name": .string(family.parent.name), "avatar": nil]
    try await answer(kite, as: family.relative, to: session, on: instance) { body in
      body["flags"] = [
        ["code": "changed", "fields": [["field": "title", "old": "Kite", "new": "Red kite"]]],
        ["code": "removed"],
        ["code": "moved", "list": ["id": .string(toys.id), "name": .string(toys.name)]],
        ["code": "moved", "list": nil],
        ["code": "occasion_moved"],
        ["code": "no_longer_shared"],
        ["code": "restored", "by": robin],
        ["code": "restored", "by": nil],
        ["code": "recipients_changed", "old_recipients": [robin], "new_recipients": [robin, morgan]],
        ["code": "recipients_changed", "old_recipients": [robin], "new_recipients": nil],
        ["code": "gift_wrapped", "paper": "gold"],
      ]
      body["needs_attention"] = true
    }

    let gift = try #require(session.givingGroups.flatMap(\.gifts).first { $0.id == kite.id })
    #expect(
      gift.flags == [
        .changed,
        .removed,
        .moved(toList: toys.name),
        .moved(toList: nil),
        .occasionMoved(to: family.groupOccasion.name),
        .noLongerShared,
        .restored(by: family.child.name),
        .restored(by: nil),
        .recipientsChanged(to: [family.child.name, family.parent.name]),
        .recipientsChanged(to: nil),
      ])
    #expect(gift.needsAttention)
    #expect(session.giftsBadge == 1)

    // The occasion that the gift moved to is hidden: the words have no name for it.
    try await answer(kite, as: family.relative, to: session, on: instance) { body in
      body["occasion"] = .null
      body["occasion_name"] = .null
      body["flags"] = [["code": "occasion_moved"], ["code": "gift_wrapped"]]
    }
    let moved = try #require(session.givingGroups.flatMap(\.gifts).first { $0.id == kite.id })
    #expect(moved.flags == [.occasionMoved(to: nil)])
    #expect(!session.isInstanceUnreachable)
  }

  // MARK: - 5. No badge, and 6. the empty state

  @Test("With no gift that needs attention the badge is absent, and with no open gift Giving is empty after a sync")
  func emptyAndNoBadge() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let session = try await signedIn(as: family.relative, on: instance)

    // The relative gave a gift once, and gives nothing now.
    #expect(session.giving.isEmpty)
    #expect(!session.given.isEmpty)
    #expect(session.givingGroups.isEmpty)
    #expect(session.giftsBadge == nil)
    #expect(session.screenState(hasRows: !session.givingGroups.isEmpty) == .empty)

    // A gift that needs no attention shows, and still no badge.
    let list = try await builder.primaryList(of: family.child)
    let spring = try await occasion("Spring", inDays: 60, of: family, builder: builder)
    let kite = try await builder.claim(
      try await builder.item("Kite", on: list, as: family.child), as: family.relative, for: spring)
    await session.syncNow()
    try await untilInStep(session, as: family.relative)
    #expect(session.givingGroups.flatMap(\.gifts).map(\.id) == [kite.id])
    #expect(session.giftsBadge == nil)
    #expect(session.screenState(hasRows: !session.givingGroups.isEmpty) == .saved(cantReach: false))
  }

  // MARK: - 7. A claim in the app

  @Test("A gift claimed in the app shows in Giving at once, with no sync")
  func claimedInTheApp() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.list("Wishes", of: family.child)
    let lamp = try await builder.item("Lamp", on: list, as: family.child)
    let session = try await signedIn(as: family.relative, on: instance)
    #expect(session.givingGroups.isEmpty)

    let mark = instance.conditioner.requests.count
    #expect(await session.claim(item: lamp.id) == .claimed)

    // At once: no wait, and no sync.
    let group = try #require(session.givingGroups.first)
    #expect(group.gifts.map(\.gift.itemID) == [lamp.id])
    #expect(group.recipients?.map(\.name) == [family.child.name])
    let asked = instance.conditioner.requests.dropFirst(mark).map(\.target)
    #expect(!asked.contains { $0.hasSuffix("/versions") })
  }
}
