import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// Given and Received, and a given gift's page: after a reveal, the gift leaves Giving and is in its giver's Given
/// and its recipient's Received, in groups by occasion, the newest first. Received is the user's own, and never a
/// child's. A recipient's copy has no note and no bought mark, and a parent never sees a child's Giving or Given.
/// See `docs/screens/gifts.md`, `docs/screens/gift.md`, and "The For {name} part" in `docs/spec.md`.
@Suite("Given, Received, and a given gift's page", .timeLimit(.minutes(2)))
@MainActor
struct GivenAndReceivedTests {
  /// A device of the instance, signed in as the person. Its first sync has ended, and the session has published
  /// what the instance names for the person. Each device has a keychain of its own.
  private func signedIn(as person: Fixture.Person, on instance: Instance) async throws -> SessionModel {
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    try await untilInStep(session, as: person)
    return session
  }

  /// Syncs, and waits until the session has published what the instance names for the person.
  private func synced(_ session: SessionModel, as person: Fixture.Person) async throws {
    #expect(await session.syncNow() == .succeeded)
    try await untilInStep(session, as: person)
  }

  /// A second person's device, on the same server, with a conditioner and a keychain of its own.
  struct Other {
    /// The device's instance. The test holds it as long as it uses the session: its conditioner stops when it goes,
    /// and the session's next sync can't reach the server.
    let instance: Instance
    let session: SessionModel
  }

  /// Signs the person in on a device of their own, on the same server as the instance.
  private func signedIn(as person: Fixture.Person, besides instance: Instance) async throws -> Other {
    let other = try await Instance(server: instance.server)
    return Other(instance: other, session: try await signedIn(as: person, on: other))
  }

  /// A shared occasion of the family, the days from today.
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

  /// The IDs of the gifts in the groups, in their order.
  private func ids(_ groups: [GiftHistoryGroup]) -> [String] {
    groups.flatMap { $0.gifts.map(\.id) }
  }

  /// The row of the gift in the groups.
  private func row(of gift: Fixture.Gift, in groups: [GiftHistoryGroup]) throws -> GiftHistoryRow {
    try #require(groups.flatMap(\.gifts).first { $0.id == gift.id })
  }

  // MARK: - 1. A reveal

  @Test("After a reveal and a sync, the gift leaves Giving, and is in the giver's Given and the recipient's Received")
  func reveal() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let spring = try await occasion("Spring", inDays: 60, of: family, builder: builder)
    let list = try await builder.primaryList(of: family.child)
    let kite = try await builder.claim(
      try await builder.item("Kite", on: list, as: family.child), as: family.relative, for: spring)
    let giver = try await signedIn(as: family.relative, on: instance)
    let other = try await signedIn(as: family.child, besides: instance)
    let recipient = other.session
    #expect(giver.giving.map(\.id).contains(kite.id))
    #expect(!ids(giver.givenGroups).contains(kite.id))
    #expect(recipient.gift(id: kite.id) == nil)
    #expect(recipient.receivedGroups.isEmpty)

    #expect(try await builder.reveal(giftsFor: family.child, within: 90) == 1)
    try await synced(giver, as: family.relative)
    try await synced(recipient, as: family.child)

    #expect(!giver.giving.map(\.id).contains(kite.id))
    #expect(giver.givingGroups.allSatisfy { !$0.gifts.map(\.id).contains(kite.id) })
    let given = try row(of: kite, in: giver.givenGroups)
    #expect(given.gift.state == .given)
    #expect(given.recipients?.map(\.name) == [family.child.name])
    #expect(given.gift.givenAt != nil)
    #expect(ids(recipient.receivedGroups) == [kite.id])
    #expect(try row(of: kite, in: recipient.receivedGroups).giverName == family.relative.name)

    // The page is a given gift's page, for both. A given gift is never an open gift's page, even for its giver.
    #expect(giver.giftPage(id: kite.id) == nil)
    #expect(recipient.giftPage(id: kite.id) == nil)
    #expect(try #require(giver.givenGiftPage(id: kite.id)).isGiver)
    #expect(try #require(recipient.givenGiftPage(id: kite.id)).isGiver == false)
    withExtendedLifetime(other) {}
  }

  // MARK: - 2. Given's groups

  @Test("Given is in groups by occasion, the newest first, each row with its recipients at the reveal")
  func givenGroups() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let spring = try await occasion("Spring", inDays: 60, of: family, builder: builder)
    let summer = try await occasion("Summer", inDays: 120, of: family, builder: builder)
    // Not a primary list: the child invites another recipient to it after the reveal.
    let childsList = try await builder.list("Wishes", of: family.child)
    let parentsList = try await builder.primaryList(of: family.parent)
    let kite = try await builder.claim(
      try await builder.item("Kite", on: childsList, as: family.child), as: family.relative, for: spring)
    let book = try await builder.claim(
      try await builder.item("Book", on: childsList, as: family.child), as: family.relative, for: spring)
    let scarf = try await builder.claim(
      try await builder.item("Scarf", on: parentsList, as: family.parent), as: family.relative, for: spring)
    let lamp = try await builder.claim(
      try await builder.item("Lamp", on: childsList, as: family.child), as: family.relative, for: summer)

    // Spring's gifts are given first, then summer's.
    #expect(try await builder.reveal(giftsFor: family.child, within: 90) == 2)
    #expect(try await builder.reveal(giftsFor: family.parent, within: 90) == 1)
    #expect(try await builder.reveal(giftsFor: family.child, within: 400) == 1)
    let session = try await signedIn(as: family.relative, on: instance)

    // The standard family's own given gift is for another occasion. This test's are summer's, then spring's.
    let groups = session.givenGroups.filter { [spring.name, summer.name].contains($0.occasionName) }
    #expect(groups.map(\.occasionName) == [summer.name, spring.name])
    #expect(groups[0].gifts.map(\.id) == [lamp.id])
    #expect(Set(groups[1].gifts.map(\.id)) == [kite.id, book.id, scarf.id])
    let onServer = try await family.relative.signedIn().get("/gifts/\(kite.id)")
    #expect(groups[1].occasionDate == onServer["occasion_date"].string)

    // Every group's gifts, and the groups, are the newest first: Given is the server's `sort=-given_at`.
    let dates = session.givenGroups.flatMap { $0.gifts.compactMap(\.gift.givenAt) }
    #expect(dates == dates.sorted(by: >))
    #expect(ids(session.givenGroups) == session.given.map(\.id))
    #expect(Set(session.givenGroups.map(\.id)).count == session.givenGroups.count)

    // Each row names who it went to.
    #expect(try row(of: kite, in: groups).recipients?.map(\.name) == [family.child.name])
    #expect(try row(of: scarf, in: groups).recipients?.map(\.name) == [family.parent.name])

    // The child's list gets a second recipient after the reveal. The given gifts keep their recipients at reveal.
    try await builder.accept(try await builder.invite(family.parent, to: childsList, as: family.child))
    try await synced(session, as: family.relative)
    let recipients = session.listPage(id: childsList.id)?.recipients.map(\.user.name) ?? []
    #expect(Set(recipients) == [family.child.name, family.parent.name])
    #expect(try row(of: kite, in: session.givenGroups).recipients?.map(\.name) == [family.child.name])
    #expect(try #require(session.givenGiftPage(id: kite.id)).recipients?.map(\.name) == [family.child.name])
  }

  @Test("A Given row has no recipients when the giver couldn't see the list, and its page has no \"For\" line")
  func givenHidden() async throws {
    let instance = try await Instance(server: try await TestServer.start())
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.primaryList(of: family.child)
    let kite = try await builder.claim(
      try await builder.item("Kite", on: list, as: family.child), as: family.relative, for: family.groupOccasion)
    try await builder.reveal(giftsFor: family.child)
    let session = try await signedIn(as: family.relative, on: instance)
    #expect(try row(of: kite, in: session.givenGroups).recipients?.map(\.name) == [family.child.name])

    // The server sends no `recipients`: the giver couldn't see the list at reveal.
    try await answer(kite, as: family.relative, to: session, on: instance) { body in
      body.removeValue(forKey: "recipients")
    }
    #expect(try row(of: kite, in: session.givenGroups).recipients == nil)
    let page = try #require(session.givenGiftPage(id: kite.id))
    #expect(page.recipients == nil)
    #expect(!page.linksList)
    #expect(page.isGiver)
  }

  // MARK: - 3. Received

  @Test("Received has the user's own gifts, and not a child's, although the copy holds the child's")
  func receivedIsOwn() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let spring = try await occasion("Spring", inDays: 60, of: family, builder: builder)
    let scarf = try await builder.claim(
      try await builder.item("Scarf", on: try await builder.primaryList(of: family.parent), as: family.parent),
      as: family.relative, for: spring)
    let kite = try await builder.claim(
      try await builder.item("Kite", on: try await builder.primaryList(of: family.child), as: family.child),
      as: family.relative, for: spring)
    try await builder.reveal(giftsFor: family.parent, within: 90)
    try await builder.reveal(giftsFor: family.child, within: 90)
    let session = try await signedIn(as: family.parent, on: instance)

    // The copy holds the gifts given to the parent's children: the child's kite, and the standard family's gift to
    // the deactivated child. Received has only the parent's own.
    #expect(session.gift(id: kite.id)?.state == .given)
    #expect(session.gift(id: family.givenGift.id)?.state == .given)
    #expect(ids(session.receivedGroups) == [scarf.id])
    #expect(session.receivedGroups.map(\.occasionName) == [spring.name])

    // The child's gifts are their own Received, for the For {name} part, and the parent may open their page.
    #expect(session.received(by: family.child.id).map(\.id) == [kite.id])
    let page = try #require(session.givenGiftPage(id: kite.id))
    #expect(!page.isGiver)
    #expect(page.recipients?.map(\.name) == [family.child.name])
  }

  // MARK: - 4. Who gave it

  @Test("A Received row has the from label and the giver, and a deleted giver by the name they had")
  func whoGaveIt() async throws {
    let instance = try await Instance(server: try await TestServer.start())
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.primaryList(of: family.child)
    let kite = try await builder.claim(
      try await builder.item("Kite", on: list, as: family.child), as: family.relative, for: family.groupOccasion,
      fromLabel: "Emma")
    let book = try await builder.claim(
      try await builder.item("Book", on: list, as: family.child), as: family.parent, for: family.groupOccasion)
    try await builder.reveal(giftsFor: family.child)
    let session = try await signedIn(as: family.child, on: instance)

    let kiteRow = try row(of: kite, in: session.receivedGroups)
    #expect(kiteRow.gift.fromLabel == "Emma")
    #expect(kiteRow.giverName == family.relative.name)
    let bookRow = try row(of: book, in: session.receivedGroups)
    #expect(bookRow.gift.fromLabel == nil)
    #expect(bookRow.giverName == family.parent.name)
    #expect(try #require(session.givenGiftPage(id: kite.id)).giverName == family.relative.name)

    // The giver is deleted: the server sends no giver, and the name they had.
    try await answer(kite, as: family.child, to: session, on: instance) { body in
      body["giver"] = .null
      body["giver_name"] = "Alex"
    }
    let deleted = try row(of: kite, in: session.receivedGroups)
    #expect(deleted.gift.giverID == nil)
    #expect(deleted.giverName == "Alex")
    #expect(deleted.gift.fromLabel == "Emma")
    #expect(try #require(session.givenGiftPage(id: kite.id)).giverName == "Alex")
  }

  // MARK: - 5. Secrecy: the note and the bought mark

  @Test("A recipient's copy of a given gift has no note and no bought mark, and the giver's page shows both")
  func noteAndBought() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.primaryList(of: family.child)
    let kite = try await builder.claim(
      try await builder.item("Kite", on: list, as: family.child), as: family.relative, for: family.groupOccasion,
      fromLabel: "Emma", note: "Blue string", isBought: true)
    try await builder.reveal(giftsFor: family.child)

    // The giver's page has the bought mark and the note, as they were.
    let giver = try await signedIn(as: family.relative, on: instance)
    let givers = try #require(giver.givenGiftPage(id: kite.id))
    #expect(givers.isGiver)
    #expect(givers.gift.note == .shown("Blue string"))
    #expect(givers.gift.isBought == .shown(true))

    // The recipient, and the recipient's parent, get neither: the server doesn't send them.
    for person in [family.child, family.parent] {
      let session = try await signedIn(as: person, besides: instance).session
      let page = try #require(session.givenGiftPage(id: kite.id), "\(person.name)")
      #expect(!page.isGiver)
      #expect(page.gift.note == .hidden, "\(person.name)")
      #expect(page.gift.isBought == .hidden, "\(person.name)")
      #expect(page.gift.fromLabel == "Emma")
      let copy = try #require(session.gift(id: kite.id))
      #expect(copy.note == .hidden && copy.isBought == .hidden && copy.flags == .hidden)
      #expect(copy.needsAttention == .hidden && copy.createdAt == .hidden)
    }
  }

  // MARK: - Secrecy: a child's Giving and Given

  @Test("A parent never sees a child's Giving or Given: neither the open gift nor the given one is in their copy")
  func childsGiving() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let spring = try await occasion("Spring", inDays: 60, of: family, builder: builder)
    let relativesList = try await builder.primaryList(of: family.relative)
    let mug = try await builder.claim(
      try await builder.item("Mug", on: relativesList, as: family.relative), as: family.child, for: spring,
      note: "Robin's note")
    let parent = try await signedIn(as: family.parent, on: instance)
    let other = try await signedIn(as: family.child, besides: instance)
    let child = other.session

    // Open: in the child's Giving, and nowhere in the parent's copy.
    #expect(child.giving.map(\.id).contains(mug.id))
    #expect(parent.gift(id: mug.id) == nil)
    #expect(parent.givingGroups.isEmpty)

    // Given: in the child's Given, and still nowhere in the parent's copy.
    try await builder.reveal(giftsFor: family.relative, within: 90)
    try await synced(child, as: family.child)
    try await synced(parent, as: family.parent)
    #expect(ids(child.givenGroups) == [mug.id])
    #expect(parent.gift(id: mug.id) == nil)
    #expect(parent.givenGroups.isEmpty)
    #expect(parent.givenGiftPage(id: mug.id) == nil)
    #expect(parent.received(by: family.child.id).allSatisfy { $0.id != mug.id })
    withExtendedLifetime(other) {}
  }

  // MARK: - 6. Empty

  @Test("Given and Received each have their empty state, although the copy holds a child's given gift")
  func empty() async throws {
    let instance = try await Instance()
    let family = try await instance.builder.standardFamily()
    let session = try await signedIn(as: family.parent, on: instance)

    // The copy holds the standard family's gift to the deactivated child. Neither part shows it.
    #expect(session.gift(id: family.givenGift.id) != nil)
    #expect(session.givenGroups.isEmpty)
    #expect(session.receivedGroups.isEmpty)
    #expect(session.screenState(hasRows: !session.givenGroups.isEmpty) == .empty)
    #expect(session.screenState(hasRows: !session.receivedGroups.isEmpty) == .empty)

    // The giver of that gift has it in Given, and nothing in Received.
    let giver = try await signedIn(as: family.relative, besides: instance).session
    #expect(ids(giver.givenGroups) == [family.givenGift.id])
    #expect(giver.receivedGroups.isEmpty)
    #expect(giver.screenState(hasRows: !giver.receivedGroups.isEmpty) == .empty)
  }

  // MARK: - 7. As at the reveal

  @Test("A given gift shows its title and price as at the reveal, after the item changed")
  func asAtReveal() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.primaryList(of: family.child)
    let image = try await builder.image(as: family.child)
    // Two are wanted, so the item stays on the list after one is given.
    let lamp = try await builder.item("Lamp", on: list, as: family.child, quantity: 2, imageIDs: [image])
    let child = try family.child.signedIn()
    try await child.send("PATCH", "/items/\(lamp.id)", json: ["price_minor": 2000, "currency": "USD"]).expecting(200)
    let gift = try await builder.claim(lamp, as: family.relative, for: family.groupOccasion)
    try await builder.reveal(giftsFor: family.child)
    let session = try await signedIn(as: family.relative, on: instance)

    // The recipient changes the item after the reveal.
    try await child.send("PATCH", "/items/\(lamp.id)", json: ["title": "Red lamp", "price_minor": 3500])
      .expecting(200)
    await session.syncNow()
    await until { session.itemPage(id: lamp.id)?.item.title == "Red lamp" }
    try await untilInStep(session, as: family.relative)

    let row = try row(of: gift, in: session.givenGroups)
    #expect(row.gift.title == "Lamp")
    #expect(row.gift.priceMinor == 2000)
    #expect(row.gift.currency == "USD")
    #expect(row.gift.image != nil)
    let page = try #require(session.givenGiftPage(id: gift.id))
    #expect(page.gift.title == "Lamp")
    #expect(page.gift.priceMinor == 2000)
    #expect(page.gift.quantity == 1)
    // The item is still on the list, so the title opens its page, which has the item as it is now.
    #expect(page.linksItem)
    #expect(session.itemPage(id: lamp.id)?.item.priceMinor == 3500)
  }

  // MARK: - The page's guard

  @Test("Neither page opens a gift that the user may not see: another giver's open gift, or a stranger's given one")
  func pageGuard() async throws {
    let instance = try await Instance(server: try await TestServer.start())
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.primaryList(of: family.child)
    let kite = try await builder.claim(
      try await builder.item("Kite", on: list, as: family.child), as: family.relative, for: family.groupOccasion)
    try await builder.reveal(giftsFor: family.child)
    let session = try await signedIn(as: family.child, on: instance)
    #expect(session.givenGiftPage(id: kite.id) != nil)

    // Another giver's gift, open, in the copy: the open gift's page is only for its giver.
    try await answer(kite, as: family.child, to: session, on: instance) { body in
      body["state"] = "open"
      body["given_at"] = .null
    }
    #expect(session.gift(id: kite.id)?.state == .open)
    #expect(session.giftPage(id: kite.id) == nil)
    #expect(session.givenGiftPage(id: kite.id) == nil)

    // A given gift whose giver, recipients and their parents are all someone else.
    try await answer(kite, as: family.child, to: session, on: instance) { body in
      body["recipients"] = [["id": .string(family.outsider.id), "name": .string(family.outsider.name), "avatar": nil]]
    }
    #expect(session.gift(id: kite.id)?.state == .given)
    #expect(session.giftPage(id: kite.id) == nil)
    #expect(session.givenGiftPage(id: kite.id) == nil)
    #expect(session.receivedGroups.isEmpty)
  }
}
