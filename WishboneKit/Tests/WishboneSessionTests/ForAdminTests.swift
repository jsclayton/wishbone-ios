import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// For the admin, on the People page: All users, All groups, and Deactivated. See "Scope" and "People" under "The
/// admin" in `docs/spec.md`, and `docs/screens/people.md`.
///
/// The tests that share a server share its admin, who sees every test's users and groups. So a test picks out its
/// own rows by their IDs, or starts a private server.
@Suite("For the admin, on the People page", .timeLimit(.minutes(1)))
@MainActor
struct ForAdminTests {
  private func signedIn(as person: Fixture.Person, on instance: Instance) async throws -> SessionModel {
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: person))
    return try #require(device.session)
  }

  @Test("Only the admin gets For the admin")
  func onlyTheAdmin() async throws {
    let instance = try await Instance()
    let family = try await instance.builder.standardFamily()

    for person in [family.parent, family.child, family.relative, family.outsider] {
      let session = try await signedIn(as: person, on: Instance(server: instance.server))
      #expect(session.peoplePage.forAdmin == nil, "\(person.name)")
    }
    let admin = try await signedIn(as: family.admin, on: instance)
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

    let admin = try await signedIn(as: family.admin, on: instance)
    let forAdmin = try #require(admin.peoplePage.forAdmin)
    let ids = Set(forAdmin.allUsers.map(\.id))
    let everyone = [
      family.admin, family.parent, family.child, family.deactivatedChild, family.relative, family.outsider,
    ]
    for person in everyone {
      #expect(ids.contains(person.id), "\(person.name)")
    }
    #expect(forAdmin.allUsers.count == ids.count)
    #expect(forAdmin.allUsers.allSatisfy { !$0.isSummary })

    let names = forAdmin.allUsers.map(\.fullName)
    #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })

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

    let admin = try await signedIn(as: family.admin, on: instance)
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

  @Test("All groups has every group by name, and Deactivated is empty when nobody is deactivated")
  func allGroupsAndNoDeactivated() async throws {
    // A private server, so that no other test's deactivated user is on it.
    let instance = try await Instance(server: try await TestServer.start())
    let builder = instance.builder
    let robin = try await builder.person("Robin")
    let morgan = try await builder.person("Morgan")
    let inner = try await builder.group("Household", users: [robin])
    let outer = try await builder.group("Family", users: [morgan], groups: [inner])
    let empty = try await builder.group("Book club")

    let admin = try await signedIn(as: builder.admin, on: instance)
    let forAdmin = try #require(admin.peoplePage.forAdmin)
    #expect(Set(forAdmin.allGroups.map(\.id)) == [inner.id, outer.id, empty.id])
    let names = forAdmin.allGroups.map(\.name)
    #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    #expect(forAdmin.deactivated.isEmpty)

    _ = try await builder.deactivate(robin)
    await admin.syncNow()
    let after = try #require(admin.peoplePage.forAdmin)
    #expect(after.deactivated.map(\.id) == [robin.id])
  }

  @Test("A user seen only through the admin's access opens with the admin's-access line, and no list")
  func adminAccess() async throws {
    let instance = try await Instance()
    let family = try await instance.builder.standardFamily()

    let admin = try await signedIn(as: family.admin, on: instance)
    let forAdmin = try #require(admin.peoplePage.forAdmin)
    #expect(forAdmin.allUsers.contains { $0.id == family.outsider.id })

    let page = try #require(admin.userPage(id: family.outsider.id))
    #expect(page.notice == .adminAccess)
    #expect(page.primaryList == nil)
    #expect(page.items.isEmpty)
    #expect(page.otherLists.isEmpty)
  }
}
