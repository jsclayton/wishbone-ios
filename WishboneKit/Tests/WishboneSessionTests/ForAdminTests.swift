import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// For the admin, on the People page: All users, All groups, and Deactivated. See "Scope" and "People" under "The
/// admin" in `docs/spec.md`, and `docs/screens/people.md`.
///
/// The tests that share a server share its admin, who sees every test's users and groups. So a test of the admin
/// on the shared server waits for the exact rows that it reads, and a test that reads the admin's whole copy starts
/// a private server and waits until the copy is in step.
@Suite("For the admin, on the People page", .timeLimit(.minutes(1)))
@MainActor
struct ForAdminTests {
  /// A new device, signed in as the person. Its first sync has ended. The test waits for what it reads.
  private func signedIn(as person: Fixture.Person, on instance: Instance) async throws -> SessionModel {
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: person))
    return try #require(device.session)
  }

  /// The admin, signed in on the shared server, once the copy holds every user of the family in full, and the
  /// deactivated child as deactivated.
  private func admin(seeing family: StandardFamily, on instance: Instance) async throws -> SessionModel {
    let admin = try await signedIn(as: family.admin, on: instance)
    let everyone = Self.everyone(of: family).map(\.id)
    await until {
      guard let allUsers = admin.peoplePage.forAdmin?.allUsers else { return false }
      let full = Dictionary(allUsers.filter { !$0.isSummary }.map { ($0.id, $0) }) { first, _ in first }
      return everyone.allSatisfy { full[$0] != nil } && full[family.deactivatedChild.id]?.isDeactivated == true
    }
    return admin
  }

  private static func everyone(of family: StandardFamily) -> [Fixture.Person] {
    [family.admin, family.parent, family.child, family.deactivatedChild, family.relative, family.outsider]
  }

  @Test("Only the admin gets For the admin")
  func onlyTheAdmin() async throws {
    let instance = try await Instance()
    let family = try await instance.builder.standardFamily()

    for person in [family.parent, family.child, family.relative, family.outsider] {
      let session = try await signedIn(as: person, on: Instance(server: instance.server))
      try await untilInStep(session, as: person)
      // Before the copy holds the user's own record, no session is the admin's. So the check counts only after.
      #expect(session.user?.record != nil, "\(person.name)")
      #expect(session.peoplePage.forAdmin == nil, "\(person.name)")
    }
    let admin = try await signedIn(as: family.admin, on: instance)
    await until { admin.user?.record != nil }
    #expect(admin.peoplePage.forAdmin != nil)
    #expect(!admin.peoplePage.isEmpty)
  }

  @Test(
    """
    All users has every user by name, also a user in no group, with "Deactivated" beside a deactivated user, and \
    only the users in full
    """
  )
  func allUsers() async throws {
    let instance = try await Instance()
    let family = try await instance.builder.standardFamily()

    let admin = try await admin(seeing: family, on: instance)
    let forAdmin = try #require(admin.peoplePage.forAdmin)
    let ids = Set(forAdmin.allUsers.map(\.id))
    let everyone = Self.everyone(of: family)
    for person in everyone {
      #expect(ids.contains(person.id), "\(person.name)")
    }
    #expect(forAdmin.allUsers.count == ids.count)
    #expect(forAdmin.allUsers.allSatisfy { !$0.isSummary })

    let deactivated = Set(forAdmin.allUsers.filter(\.isDeactivated).map(\.id))
    #expect(deactivated.contains(family.deactivatedChild.id))
    for person in everyone where person.id != family.deactivatedChild.id {
      #expect(!deactivated.contains(person.id), "\(person.name)")
    }
    #expect(forAdmin.deactivated.map(\.id).contains(family.deactivatedChild.id))
    #expect(forAdmin.deactivated.allSatisfy { $0.isDeactivated })
  }

  @Test("The search filters All users by name, in any case, and finds nobody for a name that nobody has")
  func search() async throws {
    let instance = try await Instance()
    let family = try await instance.builder.standardFamily()

    let admin = try await admin(seeing: family, on: instance)
    let forAdmin = try #require(admin.peoplePage.forAdmin)
    #expect(forAdmin.users(matching: "") == forAdmin.allUsers)
    #expect(forAdmin.users(matching: "   ") == forAdmin.allUsers)

    // Each name holds the builder's tag, so the outsider's name is theirs alone.
    #expect(forAdmin.users(matching: family.outsider.name).map(\.id) == [family.outsider.id])
    #expect(forAdmin.users(matching: family.outsider.name.uppercased()).map(\.id) == [family.outsider.id])

    // The tag is in every name of this family, and in no other test's.
    let tagged = Set(forAdmin.users(matching: instance.builder.tag).map(\.id))
    #expect(
      tagged == Set([family.parent, family.child, family.deactivatedChild, family.relative, family.outsider].map(\.id)))

    #expect(forAdmin.users(matching: "nobody \(UUID().uuidString)").isEmpty)
  }

  @Test(
    """
    All users and All groups sort by name in the locale's order, All groups has every group, and Deactivated is \
    empty when nobody is deactivated
    """
  )
  func allGroupsAndNoDeactivated() async throws {
    // A private server, so that no other test's users, groups, or deactivated user are on it.
    let instance = try await Instance(server: try await TestServer.start())
    let builder = instance.builder
    // A lowercase name before an uppercase one: the locale's order puts "alice" before "Zoe", and the order of
    // the bytes puts it after.
    let alice = try await builder.person("alice")
    let zoe = try await builder.person("Zoe")
    let robin = try await builder.person("Robin")
    let inner = try await builder.group("Household", users: [robin])
    let outer = try await builder.group("Family", users: [zoe], groups: [inner])
    let empty = try await builder.group("book club", users: [alice])

    let admin = try await signedIn(as: builder.admin, on: instance)
    try await untilInStep(admin, as: builder.admin)
    let forAdmin = try #require(admin.peoplePage.forAdmin)
    #expect(Set(forAdmin.allGroups.map(\.id)) == [inner.id, outer.id, empty.id])
    #expect(forAdmin.allGroups.map(\.id) == [empty.id, outer.id, inner.id])

    let users = forAdmin.allUsers.map(\.id)
    #expect(Set(users) == [builder.admin.id, alice.id, zoe.id, robin.id])
    let aliceIndex = try #require(users.firstIndex(of: alice.id))
    let zoeIndex = try #require(users.firstIndex(of: zoe.id))
    let robinIndex = try #require(users.firstIndex(of: robin.id))
    #expect(aliceIndex < robinIndex)
    #expect(robinIndex < zoeIndex)
    let names = forAdmin.allUsers.map(\.fullName)
    #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    #expect(forAdmin.deactivated.isEmpty)

    _ = try await builder.deactivate(robin)
    await admin.syncNow()
    await until { admin.peoplePage.forAdmin?.deactivated.map(\.id) == [robin.id] }
    try await untilInStep(admin, as: builder.admin)
    let after = try #require(admin.peoplePage.forAdmin)
    #expect(after.deactivated.map(\.id) == [robin.id])
  }

  @Test("A user seen only through the admin's access opens with the admin's-access line, and no list")
  func adminAccess() async throws {
    // A private server, so that the admin's copy can be in step before the test reads what it doesn't hold.
    let instance = try await Instance(server: try await TestServer.start())
    let family = try await instance.builder.standardFamily()

    let admin = try await signedIn(as: family.admin, on: instance)
    try await untilInStep(admin, as: family.admin)
    let forAdmin = try #require(admin.peoplePage.forAdmin)
    #expect(forAdmin.allUsers.contains { $0.id == family.outsider.id })

    let page = try #require(admin.userPage(id: family.outsider.id))
    #expect(page.notice == .adminAccess)
    #expect(page.primaryList == nil)
    #expect(page.items.isEmpty)
    #expect(page.otherLists.isEmpty)
  }
}
