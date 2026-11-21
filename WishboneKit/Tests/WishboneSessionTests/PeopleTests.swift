import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// Home's data: after sign-in, the copy holds every user, group and occasion that the session's user can see, and
/// every membership that the user can read, and a sync keeps them current. See "What the copy holds" in
/// `docs/spec.md`.
@Suite("After sign-in, the people, the groups and the occasions are in the copy", .timeLimit(.minutes(1)))
@MainActor
struct PeopleTests {
  typealias Route = NetworkConditioner.Route

  /// The time zone of every device of this suite, and of every user who signs in.
  static let zone = "Europe/Paris"

  /// The kinds of entry that the copy holds for Home.
  static let kinds: Set<String> = [
    "user", "user_summary", "group", "occasion", "group_users", "users_in_group", "users_of_occasion",
    "group_groups", "occasion_groups",
  ]

  /// Each test has a server of its own. So the versions that the instance names are the ones of this test's own
  /// family, and nothing changes them but the test.
  let server: TestServer
  let builder: FixtureBuilder

  init() async throws {
    server = try await TestServer.start()
    builder = try await FixtureBuilder(server: server)
  }

  // MARK: - Devices

  /// One person's device: the session model, and the conditioner that its requests go through.
  struct Signed {
    let person: Fixture.Person
    let instance: Instance
    let device: Device
    let session: SessionModel

    /// How many requests the device has made. The requests after this mark are those of what the test does next.
    var mark: Int {
      instance.conditioner.requests.count
    }

    /// What the device asked of the instance after the mark, oldest first, such as `GET /users/12`: the method,
    /// and the path under `/api/v2` with any query.
    func asked(since mark: Int = 0) -> [String] {
      instance.conditioner.requests.dropFirst(mark).map {
        "\($0.method) \($0.target.dropFirst(TestServer.apiPrefix.count))"
      }
    }
  }

  /// Gives the user's record the zone of this suite's devices. So a sign-in reports none, and nothing changes the
  /// user after the first sync but what the test does.
  private func setZone(of people: Fixture.Person...) async throws {
    for person in people {
      try await person.signedIn().send("PATCH", "/users/me", json: ["timezone": .string(Self.zone)]).expecting(200)
    }
  }

  /// A new device for the person, with a conditioner and a keychain of its own. It is not signed in.
  private func device(for person: Fixture.Person, storage: SessionStorage = .memory) async throws -> Signed.Fresh {
    try await setZone(of: person)
    let instance = try await Instance(server: server)
    return .init(
      person: person, instance: instance, device: instance.device(storage: storage, timeZone: .fixed(Self.zone)))
  }

  /// Signs the person in on a new device. The first sync has ended when it returns.
  private func signedIn(as person: Fixture.Person, storage: SessionStorage = .memory) async throws -> Signed {
    try await device(for: person, storage: storage).signIn()
  }

  // MARK: - The copy, and the instance's own answers

  /// What the copy holds for Home, as the entries of `GET /versions` are: `kind id version`.
  private func entries(of session: SessionModel) -> Set<String> {
    var entries: Set<String> = []
    for user in session.users {
      entries.insert("\(user.isSummary ? "user_summary" : "user") \(user.id) \(user.version)")
    }
    for group in session.groups {
      entries.insert("group \(group.id) \(group.version)")
    }
    for occasion in session.occasions {
      entries.insert("occasion \(occasion.id) \(occasion.version)")
    }
    for membership in session.memberships {
      entries.insert("\(membership.kind.rawValue) \(membership.ownerID) \(membership.version)")
    }
    return entries
  }

  /// What the instance names for the person now, for the kinds that the copy holds for Home. The person's own
  /// session asks, not the device.
  private func entries(namedFor person: Fixture.Person) async throws -> Set<String> {
    let data = try await person.signedIn().get("/versions")["data"].array ?? []
    return Set(
      data.compactMap { entry in
        guard let kind = entry["kind"].string, Self.kinds.contains(kind) else { return nil }
        return "\(kind) \(entry["id"].string ?? "") \(entry["version"].string ?? "")"
      })
  }

  /// Waits until the copy holds what the instance names for the person, each thing with its version.
  private func inStep(_ signed: Signed, _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation)
    async throws
  {
    let named = try await entries(namedFor: signed.person)
    await until { entries(of: signed.session) == named }
    #expect(entries(of: signed.session) == named, comment, sourceLocation: sourceLocation)
  }

  /// The IDs of a collection, as the person's own session reads it, in the server's order.
  private func ids(_ path: String, as person: Fixture.Person) async throws -> [String] {
    try await person.signedIn().all(path).compactMap { $0["id"].string }
  }

  private func user(_ person: Fixture.Person, in session: SessionModel) throws -> UserRow {
    try #require(session.users.first { $0.id == person.id })
  }

  // MARK: - 1. What the copy holds

  @Test("For each person of the family, the copy holds what the instance names, each thing with its version")
  func everyPersonsCopy() async throws {
    let family = try await builder.standardFamily()
    let people = [
      ("the admin", family.admin), ("the parent", family.parent), ("the child", family.child),
      ("the relative", family.relative), ("the outsider", family.outsider),
    ]
    try await setZone(of: family.admin, family.parent, family.child, family.relative, family.outsider)

    var held: [String: Set<String>] = [:]
    for (role, person) in people {
      let signed = try await signedIn(as: person)
      try await inStep(signed, "\(role)")
      held[role] = Set(entries(of: signed.session).compactMap { $0.split(separator: " ").first.map(String.init) })
    }

    // Each case that the family is for is in one copy at least.
    #expect(held["the admin"] == Self.kinds.subtracting(["user_summary"]))
    let withSummary = Self.kinds.subtracting(["group_groups", "occasion_groups"])
    #expect(held["the child"] == withSummary)
    #expect(held["the relative"] == withSummary)
    #expect(held["the parent"] == withSummary.subtracting(["user_summary"]))
    #expect(held["the outsider"] == ["user", "occasion", "users_of_occasion"])
  }

  // MARK: - 2. A full user

  @Test(
    """
    A full user has every field that its viewer gets. The time zone and the two dates are absent, not empty, for \
    a viewer who doesn't get them, and a user seen through the admin's access has no primary list
    """
  )
  func fullUsers() async throws {
    let family = try await builder.standardFamily()
    try await family.parent.signedIn().send(
      "PATCH", "/users/me",
      json: [
        "last_name": "Reyes", "good_to_know": "Size M. No more candles.",
        "birthday": ["month": 3, "day": 9, "year": 1980],
      ]
    ).expecting(200)
    try await builder.avatar(for: family.parent)

    // The relative sees the parent through a group, and is nobody's parent.
    let relative = try await signedIn(as: family.relative)
    try await inStep(relative)
    try await expectEveryField(of: relative)

    let parent = try #require(try user(family.parent, in: relative.session).record)
    #expect(parent.lastName == "Reyes")
    #expect(parent.birthday == PartialDate(month: 3, day: 9, year: 1980))
    #expect(try user(family.parent, in: relative.session).avatar != nil)
    #expect(parent.timezone == .hidden)
    #expect(parent.profileConfirmedAt == .hidden)
    #expect(parent.deactivatedAt == .hidden)
    #expect(parent.primaryListID != nil)

    // A user sees their own: the zone has a value, and the two dates are empty.
    let own = try #require(try user(family.relative, in: relative.session).record)
    #expect(own.timezone == .shown(Self.zone))
    #expect(own.profileConfirmedAt == .shown(nil))
    #expect(own.deactivatedAt == .shown(nil))

    // The admin sees every user, and those three fields of each. The admin's access shows no list.
    let admin = try await signedIn(as: family.admin)
    try await inStep(admin)
    try await expectEveryField(of: admin)

    let outsider = try #require(try user(family.outsider, in: admin.session).record)
    #expect(outsider.primaryListID == nil)
    #expect(outsider.timezone == .shown(nil))
    #expect(outsider.deactivatedAt == .shown(nil))
    let deactivated = try #require(try user(family.deactivatedChild, in: admin.session).record)
    #expect(deactivated.deactivatedAt.value != nil)
    #expect(deactivated.primaryListID == nil)
    #expect(try user(family.admin, in: admin.session).record?.primaryListID != nil)
    #expect(try user(family.admin, in: admin.session).record?.isAdmin == true)
  }

  /// Checks each full user of the copy against the user's own address, as the device's person reads it.
  private func expectEveryField(of signed: Signed, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let full = signed.session.users.filter { !$0.isSummary }
    #expect(!full.isEmpty, sourceLocation: sourceLocation)
    for row in full {
      let answer = try await signed.person.signedIn().send("GET", "/users/\(row.id)").expecting(200)
      let json = try answer.json
      let record = try #require(row.record, sourceLocation: sourceLocation)
      func expect(_ condition: Bool, _ field: String) {
        #expect(condition, "\(field) of user \(row.id)", sourceLocation: sourceLocation)
      }
      /// The moment as the server writes it.
      func text(_ date: Date?) -> String? {
        date?.formatted(.iso8601)
      }
      /// A field that the server can hide: hidden when the key is absent.
      func hideable(_ key: String) -> Hideable<String> {
        guard case .object(let members) = json, let value = members[key] else { return .hidden }
        return .shown(value.string)
      }
      func ids(_ key: String) -> [String] {
        (json[key].array ?? []).compactMap { $0["id"].string }
      }

      expect(row.version == answer.headers["etag"], "version")
      expect(row.name == json["name"].string, "name")
      expect(row.avatar?.id == json["avatar"]["id"].string, "avatar.id")
      expect(row.avatar?.url == json["avatar"]["url"].string, "avatar.url")
      expect(row.avatar.map { Double($0.width) } == json["avatar"]["width"].number, "avatar.width")
      expect(row.avatar.map { Double($0.height) } == json["avatar"]["height"].number, "avatar.height")
      expect(record.lastName == json["last_name"].string, "last_name")
      expect(Double(record.birthday.month) == json["birthday"]["month"].number, "birthday.month")
      expect(Double(record.birthday.day) == json["birthday"]["day"].number, "birthday.day")
      expect(record.birthday.year.map(Double.init) == json["birthday"]["year"].number, "birthday.year")
      expect(record.goodToKnow == json["good_to_know"].string, "good_to_know")
      expect(record.isAdmin == json["is_admin"].bool, "is_admin")
      expect(record.parentIDs == ids("parents"), "parents")
      expect(record.childIDs == ids("children"), "children")
      expect(record.primaryListID == json["primary_list"]["id"].string, "primary_list")
      expect(record.timezone == hideable("timezone"), "timezone")
      let confirmed = record.profileConfirmedAt
      expect(confirmed.isHidden == hideable("profile_confirmed_at").isHidden, "profile_confirmed_at, hidden or not")
      expect(text(confirmed.value) == json["profile_confirmed_at"].string, "profile_confirmed_at")
      let deactivated = record.deactivatedAt
      expect(deactivated.isHidden == hideable("deactivated_at").isHidden, "deactivated_at, hidden or not")
      expect(text(deactivated.value) == json["deactivated_at"].string, "deactivated_at")
      expect(text(record.createdAt) == json["created_at"].string, "created_at")
      expect(record.canEdit == json["can_edit"].bool, "can_edit")
      expect(record.canEditParents == json["can_edit_parents"].bool, "can_edit_parents")
      expect(record.canMakeLoginLink == json["can_make_login_link"].bool, "can_make_login_link")
      expect(record.canManageSessions == json["can_manage_sessions"].bool, "can_manage_sessions")
      expect(record.canDeactivate == json["can_deactivate"].bool, "can_deactivate")
      expect(record.canReactivate == json["can_reactivate"].bool, "can_reactivate")
      expect(record.canConfirmProfile == json["can_confirm_profile"].bool, "can_confirm_profile")
      expect(record.canAddOccasion == json["can_add_occasion"].bool, "can_add_occasion")
    }
  }

  // MARK: - 3. A full user who becomes a summary

  @Test(
    """
    A user who leaves the viewer's groups, and is still the parent of a user the viewer sees, becomes a summary: \
    the name and the avatar stay, and the rest goes
    """
  )
  func becomesASummary() async throws {
    let family = try await builder.standardFamily()
    try await builder.avatar(for: family.parent)
    // The relative sees the parent only through the groups: the parent's household is nested in the family.
    let relative = try await signedIn(as: family.relative)
    try await inStep(relative)
    let before = try user(family.parent, in: relative.session)
    #expect(!before.isSummary)
    #expect(before.avatar != nil)

    try await family.admin.signedIn().send(
      "DELETE", "/groups/\(family.household.id)/users/\(family.parent.id)"
    ).expecting(204)
    #expect(try await family.relative.signedIn().status(of: "/users/\(family.parent.id)") == 404)

    let mark = relative.mark
    await relative.session.sync()
    try await inStep(relative)

    let after = try user(family.parent, in: relative.session)
    #expect(after.isSummary)
    #expect(after.record == nil)
    #expect(after.name == before.name)
    #expect(after.avatar == before.avatar)
    // The child's body still holds the parent's summary, and didn't change. So no user is fetched: the copy keeps
    // the name and the avatar that it has. Only the memberships that lost the parent are read again.
    #expect(
      relative.asked(since: mark) == [
        "GET /versions",
        "GET /users?group_id=\(family.family.id)&limit=200",
        "GET /users?occasion_id=\(family.groupOccasion.id)&limit=200",
        "GET /users?occasion_id=\(family.everyoneOccasion.id)&limit=200",
      ])
    // The child still names the parent, who has no page now.
    #expect(try user(family.child, in: relative.session).record?.parentIDs == [family.parent.id])
  }

  @Test(
    """
    A summary that changes while the body that holds it is on its way is saved as the newer one. The next sync \
    reads that body again, and then the copy agrees with the instance
    """
  )
  func summaryChangesDuringThePull() async throws {
    let family = try await builder.standardFamily()
    let relative = try await signedIn(as: family.relative)
    try await family.admin.signedIn().send(
      "DELETE", "/groups/\(family.household.id)/users/\(family.parent.id)"
    ).expecting(204)
    await relative.session.sync()
    try await inStep(relative)
    let session = relative.session
    #expect(try user(family.parent, in: session).isSummary)

    // The child's body holds the parent's summary. The child changes, so the pull fetches that body.
    try await family.child.signedIn().send("PATCH", "/users/me", json: ["name": .string(builder.name("Robyn"))])
      .expecting(200)
    let hold = relative.instance.conditioner.hold(Route("GET", "/users/{id}"), at: .request)
    async let syncing: Void = session.sync()
    await hold.waitUntilHeld()
    // The parent changes their name while that fetch is on its way.
    let renamed = builder.name("Morgana")
    try await family.parent.signedIn().send("PATCH", "/users/me", json: ["name": .string(renamed)]).expecting(200)
    hold.release()
    await syncing

    // The body came with the new name, which is newer than the version that the answer named for the summary.
    await until { session.users.first { $0.id == family.parent.id }?.name == renamed }
    #expect(try user(family.parent, in: session).isSummary)

    // A summary has no address. The next answer names another version for it, so the pull reads the body that
    // holds it, from that body's own address.
    var mark = relative.mark
    await session.sync()
    try await inStep(relative)
    #expect(relative.asked(since: mark) == ["GET /versions", "GET /users/\(family.child.id)"])
    #expect(try user(family.parent, in: session).name == renamed)

    mark = relative.mark
    await session.sync()
    #expect(relative.asked(since: mark) == ["GET /versions"])
    #expect(relative.instance.conditioner.requests.last?.headers["if-none-match"] != nil)
  }

  // MARK: - 4. Groups

  @Test(
    """
    A group that the user is in by nesting has its through. Each group has its users directly in it, and its users \
    with nesting. Only the admin holds the groups in a group: anyone else holds nothing for that, which is not an \
    empty group
    """
  )
  func groups() async throws {
    let family = try await builder.standardFamily()
    let child = try await signedIn(as: family.child)
    try await inStep(child)

    let groups = Dictionary(uniqueKeysWithValues: child.session.groups.map { ($0.id, $0) })
    #expect(Set(groups.keys) == [family.household.id, family.family.id])
    #expect(groups[family.household.id]?.throughGroupID == nil)
    #expect(groups[family.family.id]?.throughGroupID == family.household.id)
    #expect(groups[family.family.id]?.name == family.family.name)
    #expect(groups[family.family.id]?.canEdit == false)

    for group in [family.household, family.family] {
      let direct = try await ids("/groups/\(group.id)/users", as: family.child)
      let nested = try await ids("/users?group_id=\(group.id)", as: family.child)
      #expect(child.session.members(.groupUsers, of: group.id) == direct)
      #expect(child.session.members(.usersInGroup, of: group.id) == nested)
    }
    // The family has the relative directly in it, and the household's users by nesting. The child can't see the
    // deactivated one.
    #expect(child.session.members(.groupUsers, of: family.family.id) == [family.relative.id])
    #expect(
      child.session.members(.usersInGroup, of: family.family.id).map(Set.init)
        == [family.relative.id, family.parent.id, family.child.id])
    // Nothing is held for the groups in a group. That is not "no groups in it".
    #expect(child.session.members(.groupGroups, of: family.family.id) == nil)
    #expect(child.session.members(.groupGroups, of: family.household.id) == nil)

    let admin = try await signedIn(as: family.admin)
    try await inStep(admin)
    #expect(admin.session.members(.groupGroups, of: family.family.id) == [family.household.id])
    // For the admin, a group with no group in it is an empty membership.
    #expect(admin.session.members(.groupGroups, of: family.household.id) == [])
    #expect(admin.session.groups.first { $0.id == family.family.id }?.throughGroupID == nil)
    #expect(admin.session.groups.first { $0.id == family.family.id }?.canEdit == true)
    #expect(
      admin.session.members(.groupUsers, of: family.household.id).map(Set.init)
        == [family.parent.id, family.child.id, family.deactivatedChild.id])
  }

  // MARK: - 5. Occasions

  @Test(
    """
    For every occasion, the users it applies to equal the server's own answer, and no request is sent for a \
    birthday or a custom occasion. The admin holds the groups of a shared occasion
    """
  )
  func occasions() async throws {
    let family = try await builder.standardFamily()
    let custom = try await builder.customOccasion("Recital", of: family.child)
    let parent = try await signedIn(as: family.parent)
    try await inStep(parent)

    // The parent sees a birthday for each of the four users, the child's custom occasion, and the two shared ones.
    let occasions = parent.session.occasions
    #expect(occasions.count(where: { $0.kind == .birthday }) == 4)
    #expect(
      Set(occasions.filter { $0.kind == .shared }.map(\.id)) == [family.groupOccasion.id, family.everyoneOccasion.id])
    for occasion in occasions {
      let applies = try await ids("/users?occasion_id=\(occasion.id)", as: family.parent)
      #expect(parent.session.members(.usersOfOccasion, of: occasion.id) == applies, "\(occasion.kind) \(occasion.id)")
    }

    let row = try #require(occasions.first { $0.id == custom.id })
    #expect(row.kind == .custom)
    #expect(row.name == custom.name)
    #expect(row.userID == family.child.id)
    #expect(row.rule == OccasionRule(kind: .once, month: 6, day: 1, year: 2040, weekday: nil, n: nil))
    #expect(row.nextDate == "2040-06-01")
    #expect(row.isEveryone == nil)
    #expect(row.canEdit)
    #expect(parent.session.members(.usersOfOccasion, of: custom.id) == [family.child.id])
    let everyone = try #require(occasions.first { $0.id == family.everyoneOccasion.id })
    #expect(everyone.isEveryone == true)
    #expect(everyone.userID == nil)
    #expect(!everyone.canEdit)

    // The users of an occasion are asked for only for the two shared ones.
    #expect(
      parent.asked().filter { $0.contains("occasion_id=") } == [
        "GET /users?occasion_id=\(family.groupOccasion.id)&limit=200",
        "GET /users?occasion_id=\(family.everyoneOccasion.id)&limit=200",
      ])
    // Only the admin reads the groups of a shared occasion. The parent holds nothing for them.
    #expect(parent.session.members(.occasionGroups, of: family.groupOccasion.id) == nil)

    let admin = try await signedIn(as: family.admin)
    try await inStep(admin)
    #expect(admin.session.members(.occasionGroups, of: family.groupOccasion.id) == [family.family.id])
    #expect(admin.session.members(.occasionGroups, of: family.everyoneOccasion.id) == [])
    for occasion in admin.session.occasions {
      let applies = try await ids("/users?occasion_id=\(occasion.id)", as: family.admin)
      #expect(admin.session.members(.usersOfOccasion, of: occasion.id) == applies, "\(occasion.kind) \(occasion.id)")
    }
    // A birthday for each of the six users, the deactivated one too.
    #expect(admin.session.occasions.count(where: { $0.kind == .birthday }) == 6)
    // The admin's access shows no custom occasion.
    #expect(!admin.session.occasions.contains { $0.id == custom.id })
    #expect(admin.session.occasions.first { $0.id == family.groupOccasion.id }?.canAttachGroup == true)
  }

  // MARK: - 6. Changes made elsewhere

  @Test(
    """
    A renamed user, a user added to a group, and a deleted custom occasion each arrive at the next sync, with only \
    the requests that the versions call for
    """
  )
  func changesArrive() async throws {
    let family = try await builder.standardFamily()
    let custom = try await builder.customOccasion("Recital", of: family.child)
    let parent = try await signedIn(as: family.parent)
    try await inStep(parent)
    let session = parent.session
    func birthday(of person: Fixture.Person) throws -> OccasionRow {
      try #require(session.occasions.first { $0.kind == .birthday && $0.userID == person.id })
    }

    // A renamed user. The relative is nobody's parent or child, so only four bodies hold the name: the user's, the
    // birthday's, the primary list's, and its recipient row. The primary list has the user's name too.
    let relativesList = try #require(try user(family.relative, in: session).record?.primaryListID)
    let renamed = builder.name("Jordy")
    try await family.relative.signedIn().send("PATCH", "/users/me", json: ["name": .string(renamed)]).expecting(200)
    var mark = parent.mark
    await session.sync()
    try await inStep(parent)
    #expect(try user(family.relative, in: session).name == renamed)
    #expect(session.list(id: relativesList)?.name == renamed)
    #expect(
      parent.asked(since: mark) == [
        "GET /versions", "GET /users/\(family.relative.id)", "GET /occasions/\(try birthday(of: family.relative).id)",
        "GET /lists/\(relativesList)/recipients?limit=200", "GET /lists/\(relativesList)",
      ])

    // A user added to a group. The parent now sees the outsider, with their birthday and their primary list, in
    // the household, in the family that the household is nested in, and in the two shared occasions. The list has
    // no items.
    try await family.admin.signedIn().post(
      "/groups/\(family.household.id)/users", ["user_id": .string(family.outsider.id)])
    mark = parent.mark
    await session.sync()
    try await inStep(parent)
    #expect(try !user(family.outsider, in: session).isSummary)
    #expect(session.members(.groupUsers, of: family.household.id)?.contains(family.outsider.id) == true)
    #expect(session.members(.usersInGroup, of: family.family.id)?.contains(family.outsider.id) == true)
    #expect(session.members(.usersOfOccasion, of: family.groupOccasion.id)?.contains(family.outsider.id) == true)
    #expect(session.members(.usersOfOccasion, of: try birthday(of: family.outsider).id) == [family.outsider.id])
    let outsidersList = try #require(try user(family.outsider, in: session).record?.primaryListID)
    #expect(session.list(id: outsidersList)?.recipientIDs == [family.outsider.id])
    #expect(
      parent.asked(since: mark) == [
        "GET /versions",
        "GET /users/\(family.outsider.id)",
        "GET /occasions/\(try birthday(of: family.outsider).id)",
        "GET /groups/\(family.household.id)/users?limit=200",
        "GET /users?group_id=\(family.household.id)&limit=200",
        "GET /users?group_id=\(family.family.id)&limit=200",
        "GET /users?occasion_id=\(family.groupOccasion.id)&limit=200",
        "GET /users?occasion_id=\(family.everyoneOccasion.id)&limit=200",
        "GET /lists/\(outsidersList)/recipients?limit=200",
        "GET /lists/\(outsidersList)",
      ])

    // A deleted custom occasion. Nothing is fetched: the versions say that it went, with its users.
    #expect(session.members(.usersOfOccasion, of: custom.id) == [family.child.id])
    try await family.child.signedIn().send("DELETE", "/occasions/\(custom.id)").expecting(204)
    mark = parent.mark
    await session.sync()
    try await inStep(parent)
    #expect(!session.occasions.contains { $0.id == custom.id })
    #expect(session.members(.usersOfOccasion, of: custom.id) == nil)
    #expect(parent.asked(since: mark) == ["GET /versions"])

    // The copy agrees with that answer, so the next sync is one request, answered 304.
    mark = parent.mark
    await session.sync()
    #expect(parent.asked(since: mark) == ["GET /versions"])
    #expect(parent.instance.conditioner.requests.last?.headers["if-none-match"] != nil)
    #expect(!session.isInstanceUnreachable)
  }

  // MARK: - 7. Home's data first

  @Test("With the lists' requests held, the people, the groups and the occasions already read from the copy")
  func homeFirst() async throws {
    let family = try await builder.standardFamily()
    let list = try await builder.primaryList(of: family.parent)
    for title in ["Kite", "Puzzle"] {
      _ = try await builder.item(title, on: list, as: family.parent)
    }
    let fresh = try await device(for: family.parent)
    let link = try await fresh.instance.loginLink(for: family.parent)
    let conditioner = fresh.instance.conditioner

    // No request for a list, or for an item, reaches the instance.
    let items = conditioner.hold(Route("GET", "/lists/{id}/items"), at: .request)
    let holds = [
      items, conditioner.hold(Route("GET", "/lists/{id}"), at: .request),
      conditioner.hold(Route("GET", "/items/{id}"), at: .request),
    ]
    async let signingIn: Void = fresh.device.signIn(pasting: link)
    await items.waitUntilHeld()

    let session = try #require(fresh.device.session)
    let signed = Signed(person: family.parent, instance: fresh.instance, device: fresh.device, session: session)
    try await inStep(signed)
    #expect(session.users.count == 4)
    #expect(session.groups.count == 2)
    #expect(session.occasions.count == 6)
    #expect(session.user?.name == family.parent.name)
    #expect(session.primaryList == nil)
    #expect(session.primaryListItems.isEmpty)

    holds.forEach { $0.release() }
    await signingIn
    await until { session.primaryListItems.map(\.title) == ["Kite", "Puzzle"] }
    #expect(session.primaryList?.id == list.id)
  }

  // MARK: - 8. More than one page

  @Test("A collection that is longer than one page is whole in the copy")
  func longCollection() async throws {
    let robin = try await builder.person("Robin")
    var names: Set<String> = []
    for number in 1...(APIClient.pageSize + 1) {
      names.insert(try await builder.customOccasion("Occasion \(number)", of: robin).name)
    }
    let signed = try await signedIn(as: robin)
    try await inStep(signed)

    let custom = signed.session.occasions.filter { $0.kind == .custom }
    #expect(custom.count == APIClient.pageSize + 1)
    #expect(Set(custom.map(\.name)) == names)
    #expect(signed.session.occasions.count(where: { $0.kind == .birthday }) == 1)
    // The collection came in two pages.
    let pages = signed.asked().filter { $0.hasPrefix("GET /occasions") }
    #expect(pages.count == 2)
    #expect(pages.first == "GET /occasions?limit=200")
    #expect(pages.last?.hasPrefix("GET /occasions?limit=200&cursor=") == true)
    // Each custom occasion applies to its own user, and none of them was asked for.
    #expect(custom.allSatisfy { signed.session.members(.usersOfOccasion, of: $0.id) == [robin.id] })
    #expect(!signed.asked().contains { $0.contains("occasion_id=") })
  }

  @Test(
    """
    An occasion that changes its place between two pages is on neither. It is named, and not in the collection: \
    its own address says that it is not gone, and it stays in the copy
    """
  )
  func betweenTwoPages() async throws {
    let robin = try await builder.person("Robin")
    for number in 1...(APIClient.pageSize + 3) {
      _ = try await builder.customOccasion("Occasion \(number)", of: robin)
    }
    let signed = try await signedIn(as: robin)
    try await inStep(signed)
    let session = signed.session
    let own = try robin.signedIn()

    // The collection's order is the soonest first. Every custom occasion is on one date, so the last one of the
    // collection is on its second page.
    let order = try await ids("/occasions", as: robin)
    let last = try #require(order.last)
    // Three occasions change, which is more than the collection has pages. So the pull reads the collection.
    for id in order.dropFirst().prefix(3) {
      try await own.send("PATCH", "/occasions/\(id)", json: ["name": .string(builder.name("Renamed \(id)"))])
        .expecting(200)
    }

    // The instance has answered with the first page, and that answer is on its way.
    let hold = signed.instance.conditioner.hold(Route("GET", "/occasions"))
    var mark = signed.mark
    async let syncing: Void = session.sync()
    await hold.waitUntilHeld()
    // The last occasion moves to an earlier date: its place is now on the first page, which is already made.
    let moved = builder.name("Moved")
    try await own.send(
      "PATCH", "/occasions/\(last)",
      json: ["name": .string(moved), "rule": ["kind": "once", "year": 2039, "month": 1, "day": 1]]
    ).expecting(200)
    hold.release()
    await syncing

    // Neither page had it. Its own address did.
    await until { session.occasions.first { $0.id == last }?.name == moved }
    #expect(signed.asked(since: mark).last == "GET /occasions/\(last)")
    #expect(session.occasions.count == order.count)
    #expect(session.occasions.first { $0.id == last }?.nextDate == "2039-01-01")
    try await inStep(signed)

    // The fetch gave another version than the answer named, so that answer's ETag is not kept. The next sync
    // compares again, and the copy already has every version that the instance names.
    mark = signed.mark
    await session.sync()
    #expect(signed.asked(since: mark) == ["GET /versions"])
    #expect(signed.instance.conditioner.requests.last?.headers["if-none-match"] == nil)
  }

  // MARK: - 9. With no network

  @Test("After a relaunch with the network dropped, the people, the groups and the occasions still read")
  func relaunchOffline() async throws {
    let family = try await builder.standardFamily()
    try await builder.avatar(for: family.parent)
    let folder = try ScratchDirectory("device")
    let fresh = try await device(for: family.child, storage: .folder(folder.url))
    let saved: (users: [UserRow], groups: [GroupRow], occasions: [OccasionRow], memberships: [MembershipRow])
    do {
      // The device goes at the end of this scope, as the app does when it ends.
      let signed = try await fresh.signIn()
      try await inStep(signed)
      let session = signed.session
      saved = (session.users, session.groups, session.occasions, session.memberships)
    }
    #expect(saved.users.contains { $0.isSummary })
    #expect(saved.users.contains { $0.avatar != nil })
    #expect(!saved.groups.isEmpty && !saved.occasions.isEmpty && !saved.memberships.isEmpty)

    fresh.instance.conditioner.dropEverything()
    let relaunched = fresh.instance.device(storage: .folder(folder.url), timeZone: .fixed(Self.zone))

    // What is saved shows at once, before anything is asked of the instance.
    let session = try #require(relaunched.session)
    #expect(session.users == saved.users)
    #expect(session.groups == saved.groups)
    #expect(session.occasions == saved.occasions)
    #expect(session.memberships == saved.memberships)
    #expect(session.user?.id == family.child.id)

    await session.sync()
    #expect(session.isInstanceUnreachable)
    #expect(session.users == saved.users)
    #expect(session.memberships == saved.memberships)
  }
}

extension PeopleTests.Signed {
  /// A device that is not signed in yet.
  @MainActor
  struct Fresh {
    let person: Fixture.Person
    let instance: Instance
    let device: Device

    /// Signs the person in. The first sync has ended when it returns.
    func signIn() async throws -> PeopleTests.Signed {
      await device.signIn(pasting: try await instance.loginLink(for: person))
      return .init(person: person, instance: instance, device: device, session: try #require(device.session))
    }
  }
}
