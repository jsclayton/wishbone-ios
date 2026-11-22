import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// Home's People, from the copy: Your children, Your parents, and the user's groups, each with its users. See
/// "Home" in `docs/spec.md`, and `docs/screens/home.md`.
@Suite("Home's People", .timeLimit(.minutes(1)))
@MainActor
struct HomePeopleTests {
  /// A part of People as a test names it: its words, and the IDs of its users.
  struct Part: Equatable, CustomStringConvertible {
    let name: String
    let users: Set<String>

    var description: String { "\(name): \(users.sorted())" }
  }

  /// A new device, signed in as the person. Its first sync has ended, and the session publishes all that it
  /// wrote. Each device has a keychain of its own, so a test can sign several people in on one server.
  private func signedIn(as person: Fixture.Person, on server: TestServer) async throws -> SessionModel {
    try await signedIn(as: person, on: try await Instance(server: server))
  }

  private func signedIn(as person: Fixture.Person, on instance: Instance) async throws -> SessionModel {
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    try await untilInStep(session, as: person)
    return session
  }

  /// The session's People, as parts that a test can compare.
  private func parts(of session: SessionModel) -> [Part] {
    session.people.map { part in
      let name =
        switch part.kind {
        case .children: "Your children"
        case .parents: "Your parents"
        case .group(let group, let through): through.map { "\(group.name) through \($0.name)" } ?? group.name
        }
      return Part(name: name, users: Set(part.users.map(\.id)))
    }
  }

  private func deactivated(in session: SessionModel) -> Set<String> {
    Set(session.people.flatMap(\.users).filter(\.isDeactivated).map(\.id))
  }

  @Test(
    "A parent gets Your children, with the deactivated child marked, and their groups, with \"through\" for a nested one"
  )
  func parent() async throws {
    let instance = try await Instance()
    let family = try await instance.builder.standardFamily()
    let session = try await signedIn(as: family.parent, on: instance)

    let children = [family.child.id, family.deactivatedChild.id]
    #expect(
      parts(of: session) == [
        Part(name: "Your children", users: Set(children)),
        // The parent is directly in the household, and in the family through it.
        Part(
          name: "\(family.family.name) through \(family.household.name)",
          users: Set(children + [family.relative.id])),
        Part(name: family.household.name, users: Set(children)),
      ])
    #expect(session.people.first?.users.map(\.id).sorted() == children.sorted())
    #expect(deactivated(in: session) == [family.deactivatedChild.id])
  }

  @Test("A child gets Your parents, and their groups")
  func child() async throws {
    let instance = try await Instance()
    let family = try await instance.builder.standardFamily()
    let session = try await signedIn(as: family.child, on: instance)

    // The deactivated child is left out for their sibling: only the user, their parents, and the admin see them.
    #expect(
      parts(of: session) == [
        Part(name: "Your parents", users: [family.parent.id]),
        Part(
          name: "\(family.family.name) through \(family.household.name)",
          users: [family.parent.id, family.relative.id]),
        Part(name: family.household.name, users: [family.parent.id]),
      ])
    #expect(deactivated(in: session).isEmpty)
  }

  @Test("The user is never among their own people, and a user shows once in each part that has them")
  func neverTheUser() async throws {
    let instance = try await Instance()
    let family = try await instance.builder.standardFamily()
    for person in [family.parent, family.child, family.relative] {
      let session = try await signedIn(as: person, on: instance.server)
      #expect(!session.people.isEmpty, "\(person.name)")
      for part in session.people {
        let ids = part.users.map(\.id)
        #expect(!ids.contains(person.id), "\(person.name) is in their own \(part.id)")
        #expect(Set(ids).count == ids.count, "\(person.name)'s \(part.id) has a user twice")
      }
    }

    // The child shares the household with their parent, so the parent sees them in Your children and in it.
    let parent = try await signedIn(as: family.parent, on: instance.server)
    let withChild = parent.people.filter { $0.users.contains { $0.id == family.child.id } }
    #expect(withChild.map(\.id).contains("children"))
    #expect(withChild.map(\.id).contains("group \(family.household.id)"))
  }

  @Test("The admin gets only the groups that the admin is in, and sees \"Deactivated\"")
  func admin() async throws {
    // The admin sees every group of the instance, so the test has a server of its own.
    let instance = try await Instance(server: try await TestServer.start())
    let family = try await instance.builder.standardFamily()
    // The household is nested in the admin's group, so the admin is in neither the household nor the family.
    let own = try await instance.builder.group(
      "Admins", users: [family.admin, family.outsider], groups: [family.household])
    let session = try await signedIn(as: family.admin, on: instance)

    // The copy has every group, and People has only the admin's own.
    #expect(Set(session.groups.map(\.id)).isSuperset(of: [family.family.id, family.household.id, own.id]))
    let household = [family.parent.id, family.child.id, family.deactivatedChild.id]
    #expect(parts(of: session) == [Part(name: own.name, users: Set(household + [family.outsider.id]))])
    #expect(deactivated(in: session) == [family.deactivatedChild.id])
  }

  @Test("\"Deactivated\" shows only to a viewer who gets the user's deactivated_at")
  func deactivatedOnlyToThoseWhoGetIt() async throws {
    let instance = try await Instance()
    let family = try await instance.builder.standardFamily()

    let parent = try await signedIn(as: family.parent, on: instance.server)
    #expect(deactivated(in: parent) == [family.deactivatedChild.id])

    // The relative shares the family with the deactivated child, and doesn't get them at all. Nobody else in
    // their People is marked.
    let relative = try await signedIn(as: family.relative, on: instance.server)
    #expect(!relative.people.isEmpty)
    #expect(!relative.people.flatMap(\.users).contains { $0.id == family.deactivatedChild.id })
    #expect(deactivated(in: relative).isEmpty)
    #expect(relative.people.flatMap(\.users).allSatisfy { $0.record?.deactivatedAt.isHidden == true })
  }

  @Test("A user with nobody to see gets the empty state after a sync, and can't reach before any sync")
  func nobodyToSee() async throws {
    let instance = try await Instance()
    let family = try await instance.builder.standardFamily()

    let session = try await signedIn(as: family.outsider, on: instance)
    #expect(session.people.isEmpty)
    #expect(session.screenState(hasRows: !session.people.isEmpty) == .empty)

    // A launch that keeps the session, with nothing saved, and no network: never the empty state.
    let relaunched = try #require(instance.device().session)
    #expect(relaunched.people.isEmpty)
    #expect(relaunched.screenState(hasRows: !relaunched.people.isEmpty) == .loading)
    instance.conditioner.dropEverything()
    #expect(await relaunched.syncNow() == .unreachable)
    #expect(relaunched.screenState(hasRows: !relaunched.people.isEmpty) == .cantReach)
  }
}
