import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// The People page, as everyone sees it: Your children, Your parents, and the user's groups, each with its users by
/// name. See "People" in `docs/spec.md`, and `docs/screens/people.md`.
@Suite("The People page", .timeLimit(.minutes(1)))
@MainActor
struct PeoplePageTests {
  /// A new device, signed in as the person. Each device has a keychain of its own, so a test can sign several
  /// people in on one server.
  private func signedIn(as person: Fixture.Person, on server: TestServer) async throws -> SessionModel {
    try await signedIn(as: person, on: try await Instance(server: server))
  }

  private func signedIn(as person: Fixture.Person, on instance: Instance) async throws -> SessionModel {
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: person))
    return try #require(device.session)
  }

  @Test("The page has the same parts, in the same order, as Home's People, for a parent and for a child")
  func sameAsHome() async throws {
    let instance = try await Instance()
    let family = try await instance.builder.standardFamily()

    let parent = try await signedIn(as: family.parent, on: instance)
    #expect(parent.peoplePage.parts.map(\.id).first == "children")
    #expect(!parent.peoplePage.parts.map(\.id).contains("parents"))
    #expect(parent.peoplePage.parts.count == 3)
    #expect(parent.peoplePage.parts == parent.people)

    let child = try await signedIn(as: family.child, on: instance.server)
    #expect(child.peoplePage.parts.map(\.id).first == "parents")
    #expect(!child.peoplePage.parts.map(\.id).contains("children"))
    #expect(child.peoplePage.parts.count == 3)
    #expect(child.peoplePage.parts == child.people)
  }

  @Test("A row has the last name when the copy has the full user, and only the name when the user has none")
  func lastName() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let parent = try await builder.person("Morgan", lastName: "Clark")
    let child = try await builder.person("Robin", parents: [parent])
    let cousin = try await builder.person("Jordan")
    _ = try await builder.group("Clarks", users: [parent, child, cousin])

    let session = try await signedIn(as: child, on: instance)
    let rows = session.peoplePage.parts.flatMap(\.users)
    let parentRow = try #require(rows.first { $0.id == parent.id })
    #expect(!parentRow.isSummary)
    #expect(parentRow.fullName.contains(parent.name))
    #expect(parentRow.fullName.contains("Clark"))
    #expect(parentRow.fullName != parent.name)

    let cousinRow = try #require(rows.first { $0.id == cousin.id })
    #expect(cousinRow.fullName == cousin.name)
  }

  @Test("A user with nobody to see gets the empty state")
  func nobodyToSee() async throws {
    let instance = try await Instance()
    let family = try await instance.builder.standardFamily()

    let session = try await signedIn(as: family.outsider, on: instance)
    #expect(session.peoplePage.isEmpty)
    #expect(session.screenState(hasRows: !session.peoplePage.isEmpty) == .empty)
  }
}
