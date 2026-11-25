import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// The Occasions screen's Coming up: every occasion with a next date, soonest first, the user's own included. It is
/// pure, as Home's is. See `docs/screens/occasions.md`.
@Suite("The Occasions screen", .timeLimit(.minutes(1)))
struct OccasionsTests {
  static let zone = HomeOccasionsTests.zone
  static let me = HomeOccasionsTests.me

  static func rows(_ occasions: [HomeOccasions.Occasion], today: Date = HomeOccasionsTests.now) -> [HomeOccasion] {
    HomeOccasions.rows(
      occasions: occasions, people: HomeOccasionsTests.people, me: me, gifts: [], today: today, timeZone: zone,
      within: nil)
  }

  @Test("Every occasion with a next date shows, soonest first, the user's own and those past 60 days included")
  func everyOccasion() {
    let rows = Self.rows([
      HomeOccasionsTests.occasion("3", on: "2026-11-20"),
      HomeOccasionsTests.occasion("4", .shared, name: "Holiday", everyone: true, on: "2026-12-25"),
      HomeOccasionsTests.occasion("1", user: Self.me, on: "2026-03-02"),
      HomeOccasionsTests.occasion("5", .custom, name: "Recital", user: "13", on: "2026-05-01"),
      // Past its date in the device's zone, with no date left, and of a person who is not in the copy.
      HomeOccasionsTests.occasion("6", on: "2026-02-28"),
      HomeOccasionsTests.occasion("7", on: nil),
      HomeOccasionsTests.occasion("8", user: "99", on: "2026-03-03"),
    ])
    #expect(rows.map(\.id) == ["1", "5", "3", "4"])
    #expect(rows.map(\.daysLeft) == [1, 61, 264, 299])
    #expect(rows.first?.whose == .own)
  }

  @Test("A tap opens the person's page, the user's primary list, or the shared occasion's page")
  func destination() {
    let rows = Self.rows([
      HomeOccasionsTests.occasion("1", user: Self.me, on: "2026-03-02"),
      HomeOccasionsTests.occasion("3", on: "2026-03-04"),
      HomeOccasionsTests.occasion("4", .shared, name: "Holiday", on: "2026-12-25"),
    ])
    #expect(rows.map(\.destination) == [.list(id: "70"), .user(id: "12"), .sharedOccasion(id: "4")])
  }
}

/// A shared occasion's page counts as the web's page does: the user is left out, a gift counts only on the
/// occasion's next date, and the days left follow Home's rule. It is pure. See `docs/screens/occasions.md`.
@Suite("A shared occasion's people and counts", .timeLimit(.minutes(1)))
struct SharedOccasionCountsTests {
  static let me = HomeOccasionsTests.me

  static func gift(
    _ recipients: [String], occasion: String? = "4", on date: String = "2026-12-25"
  ) -> SharedOccasionPage.Gift {
    SharedOccasionPage.Gift(occasionID: occasion, occasionDate: date, recipientIDs: recipients)
  }

  @Test("The user is left out of the occasion's people, and each other user has the gifts that are for them")
  func leavesTheUserOut() {
    let counts = SharedOccasionPage.counts(
      memberIDs: ["12", Self.me, "13", "14"], me: Self.me, occasionID: "4", nextDate: "2026-12-25",
      gifts: [
        Self.gift(["12"]), Self.gift(["12", "13"]),
        // Another occasion, another date of this one, and an occasion the giver can't see: none counts.
        Self.gift(["12"], occasion: "5"), Self.gift(["13"], on: "2025-12-25"), Self.gift(["13"], occasion: nil),
      ])
    #expect(
      counts == [
        .init(id: "12", fromYou: 2), .init(id: "13", fromYou: 1), .init(id: "14", fromYou: 0),
      ])
  }

  @Test("An occasion with no next date counts no gift")
  func noNextDate() {
    let counts = SharedOccasionPage.counts(
      memberIDs: ["12"], me: Self.me, occasionID: "4", nextDate: nil, gifts: [Self.gift(["12"])])
    #expect(counts == [.init(id: "12", fromYou: 0)])
  }

  @Test("People the copy doesn't have yet are not an occasion that reaches nobody")
  func notInTheCopyYet() {
    let gifts = [Self.gift(["12"])]
    #expect(
      SharedOccasionPage.counts(memberIDs: nil, me: Self.me, occasionID: "4", nextDate: "2026-12-25", gifts: gifts)
        == nil)
    #expect(
      SharedOccasionPage.counts(memberIDs: [], me: Self.me, occasionID: "4", nextDate: "2026-12-25", gifts: gifts)
        == [])
    // An occasion for only the user reaches nobody else.
    #expect(
      SharedOccasionPage.counts(
        memberIDs: [Self.me], me: Self.me, occasionID: "4", nextDate: "2026-12-25", gifts: gifts) == [])
  }

  @Test("The days left follow Home's rule: a next date that is yesterday in the device's zone has none")
  func daysLeft() {
    let now = HomeOccasionsTests.now
    let zone = HomeOccasionsTests.zone
    #expect(SharedOccasionPage.daysLeft(until: "2026-03-01", today: now, timeZone: zone) == 0)
    #expect(SharedOccasionPage.daysLeft(until: "2026-03-02", today: now, timeZone: zone) == 1)
    #expect(SharedOccasionPage.daysLeft(until: "2026-12-25", today: now, timeZone: zone) == 299)
    #expect(SharedOccasionPage.daysLeft(until: "2026-02-28", today: now, timeZone: zone) == nil)
    #expect(SharedOccasionPage.daysLeft(until: nil, today: now, timeZone: zone) == nil)
    #expect(SharedOccasionPage.daysLeft(until: "not a date", today: now, timeZone: zone) == nil)
    // Home leaves the same date out of Coming up.
    let rows = OccasionsTests.rows([HomeOccasionsTests.occasion("4", .shared, name: "Holiday", on: "2026-02-28")])
    #expect(rows.isEmpty)
  }
}

/// A shared occasion's page, and the Occasions screen, as the session model reads them from a copy that a real
/// server filled. See "Shared occasions" in `docs/spec.md`, and `docs/screens/occasions.md`.
///
/// On the shared server, other tests add occasions for everyone, and each new user joins their users. So these
/// tests wait for the exact rows they read, and never for the copy to be in step for the occasions.
@Suite("A shared occasion's page", .timeLimit(.minutes(1)))
@MainActor
struct SharedOccasionPageTests {
  /// A giver, Emma and Sam in one group, and Christmas attached to it. The giver has two open gifts for Emma on
  /// Christmas, one for Sam on Christmas, and one for Emma on her birthday, which doesn't count. Emma's "Shared"
  /// list has Sam as a recipient too, and the giver has a gift on it for Christmas, which counts for both.
  struct Cousins {
    let giver: Fixture.Person
    let emma: Fixture.Person
    let sam: Fixture.Person
    let group: Fixture.Group
    let christmas: Fixture.Occasion
  }

  private func cousins(on instance: Instance) async throws -> Cousins {
    let builder = instance.builder
    let giver = try await builder.person("Robin")
    let emma = try await builder.person("Emma")
    let sam = try await builder.person("Sam")
    let group = try await builder.group("Cousins", users: [giver, emma, sam])
    let christmas = try await builder.sharedOccasion("Christmas", month: 12, day: 25, groups: [group])

    let emmaList = try await builder.primaryList(of: emma)
    let kite = try await builder.item("Kite", on: emmaList, as: emma)
    let puzzle = try await builder.item("Puzzle", on: emmaList, as: emma)
    let ball = try await builder.item("Ball", on: emmaList, as: emma)
    let samList = try await builder.primaryList(of: sam)
    let book = try await builder.item("Book", on: samList, as: sam)
    _ = try await builder.claim(kite, as: giver, for: christmas)
    _ = try await builder.claim(puzzle, as: giver, for: christmas, isBought: true)
    _ = try await builder.claim(ball, as: giver, for: try await builder.birthday(of: emma, as: giver))
    _ = try await builder.claim(book, as: giver, for: christmas)
    let shared = try await builder.list("Shared", of: emma)
    try await builder.accept(try await builder.invite(sam, to: shared, as: emma))
    let games = try await builder.item("Games", on: shared, as: emma)
    _ = try await builder.claim(games, as: giver, for: christmas)
    return Cousins(giver: giver, emma: emma, sam: sam, group: group, christmas: christmas)
  }

  /// A new device on the instance's server, signed in as the person. Each device has a keychain of its own, so a
  /// test can sign several people in on one server. The device reaches the server only while its instance lives, so
  /// a test that syncs again later signs in with `instance.device()` itself.
  private func signedIn(as person: Fixture.Person, on instance: Instance) async throws -> SessionModel {
    let instance = try await Instance(server: instance.server)
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: person))
    return try #require(device.session)
  }

  @Test("The page's users are the server's users of the occasion but the caller, each with the caller's own count")
  func usersAndCounts() async throws {
    let instance = try await Instance()
    let cousins = try await cousins(on: instance)
    let session = try await signedIn(as: cousins.giver, on: instance)
    let id = cousins.christmas.id
    let server = try await cousins.giver.signedIn().all("/users?occasion_id=\(id)").compactMap { $0["id"].string }
    #expect(Set(server) == [cousins.giver.id, cousins.emma.id, cousins.sam.id])
    // The caller is on the occasion, and the page leaves them out, as the web's does.
    let others = server.filter { $0 != cousins.giver.id }
    await until {
      session.sharedOccasionPage(id: id)?.people?.map(\.id) == others && session.giving.count == 5
    }

    let page = try #require(session.sharedOccasionPage(id: id))
    let people = try #require(page.people)
    #expect(people.map(\.id) == others)
    let counts = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.fromYou) })
    // Emma: the kite, the puzzle and the games. Sam: the book and the games. Emma's birthday doesn't count.
    #expect(counts == [cousins.emma.id: 3, cousins.sam.id: 2])
    #expect(page.name == cousins.christmas.name)
    #expect(page.date?.hasSuffix("-12-25") == true)
    #expect(page.daysLeft != nil)
    // Not for everyone, and the giver is not the admin: no "Everyone", and no group names.
    #expect(!page.isEveryone)
    #expect(page.groupNames.isEmpty)

    // Someone else's counts are their own: Emma has none for anybody.
    let emma = try await signedIn(as: cousins.emma, on: instance)
    await until { emma.sharedOccasionPage(id: id)?.people?.count == 2 }
    #expect(emma.sharedOccasionPage(id: id)?.people?.map(\.id).contains(cousins.emma.id) == false)
    #expect(emma.sharedOccasionPage(id: id)?.people?.map(\.fromYou) == [0, 0])
  }

  @Test("The Occasions screen has every occasion with a next date, the user's own and the shared one included")
  func occasionsScreen() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    // The giver's own birthday is past Home's 60 days.
    let giver = try await builder.person("Robin", birthday: FixtureBuilder.monthAndDay(daysFromNow: 180))
    let emma = try await builder.person("Emma", birthday: FixtureBuilder.monthAndDay(daysFromNow: 10))
    let group = try await builder.group("Cousins", users: [giver, emma])
    let christmas = try await builder.sharedOccasion("Christmas", month: 12, day: 25, groups: [group])
    let own = try await builder.birthday(of: giver, as: giver)
    let emmasBirthday = try await builder.birthday(of: emma, as: giver)
    let session = try await signedIn(as: giver, on: instance)
    let ids = [own.id, emmasBirthday.id, christmas.id]
    await until { ids.allSatisfy { id in session.occasions.contains { $0.id == id } } }

    let rows = session.everyOccasion()
    let mine = rows.filter { ids.contains($0.id) }
    #expect(Set(mine.map(\.id)) == Set(ids))
    #expect(mine.map(\.daysLeft) == mine.map(\.daysLeft).sorted())
    #expect(rows.map(\.daysLeft) == rows.map(\.daysLeft).sorted())
    #expect(mine.first { $0.id == own.id }?.whose == .own)
    #expect(mine.first { $0.id == christmas.id }?.destination == .sharedOccasion(id: christmas.id))
    #expect(mine.first { $0.id == emmasBirthday.id }?.destination == .user(id: emma.id))
    // Home has only the next 60 days, so the giver's own birthday is on the Occasions screen alone.
    #expect(!session.homeOccasions().comingUp.contains { $0.id == own.id })
  }

  @Test("An occasion for everyone says so")
  func everyone() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let giver = try await builder.person("Robin")
    let holiday = try await builder.sharedOccasion("Holiday", month: 12, day: 31, isEveryone: true)
    let session = try await signedIn(as: giver, on: instance)
    let id = holiday.id
    // The user is left out of their own page, so wait for the occasion's membership itself.
    await until { session.members(.usersOfOccasion, of: id)?.contains(giver.id) == true }

    let page = try #require(session.sharedOccasionPage(id: id))
    #expect(page.isEveryone)
    #expect(page.groupNames.isEmpty)
  }

  @Test("A deleted shared occasion has no page")
  func deleted() async throws {
    let instance = try await Instance()
    let cousins = try await cousins(on: instance)
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: cousins.giver))
    let session = try #require(device.session)
    let id = cousins.christmas.id
    // The first sync has ended before the delete, so the next Sync now is a sync of its own.
    try await untilInStep(session, as: cousins.giver)
    await until { session.sharedOccasionPage(id: id) != nil }

    _ = try await instance.builder.admin.signedIn().send("DELETE", "/occasions/\(id)").expecting(204)
    _ = await session.syncNow()
    await until { session.sharedOccasionPage(id: id) == nil }
    #expect(session.sharedOccasionPage(id: id) == nil)
    #expect(!session.everyOccasion().contains { $0.id == id })
  }

  @Test("A birthday or a custom occasion has no page of its own")
  func notShared() async throws {
    let instance = try await Instance()
    let cousins = try await cousins(on: instance)
    let session = try await signedIn(as: cousins.giver, on: instance)
    let birthday = try await instance.builder.birthday(of: cousins.emma, as: cousins.giver)
    let id = birthday.id
    await until { session.occasions.contains { $0.id == id } }
    #expect(session.sharedOccasionPage(id: id) == nil)
  }

  // The admin sees every test's users, so an admin test starts a private server (see `ForAdminTests`).
  @Test("The admin sees the occasion's groups, and an occasion that reaches nobody the admin sees has no users")
  func admin() async throws {
    let instance = try await Instance(server: try await TestServer.start())
    let cousins = try await cousins(on: instance)
    let builder = instance.builder
    let empty = try await builder.group("Nobody")
    let nobody = try await builder.sharedOccasion("Reunion", month: 8, day: 1, groups: [empty])
    let admin = try await signedIn(as: builder.admin, on: instance)
    try await untilInStep(admin, as: builder.admin)
    let christmas = cousins.christmas.id
    let reunion = nobody.id
    await until {
      admin.sharedOccasionPage(id: christmas)?.groupNames.isEmpty == false
        && admin.sharedOccasionPage(id: reunion)?.people != nil
    }

    #expect(admin.sharedOccasionPage(id: christmas)?.groupNames == [cousins.group.name])
    let page = try #require(admin.sharedOccasionPage(id: reunion))
    #expect(page.people == [])
    #expect(page.groupNames == [empty.name])
  }
}
