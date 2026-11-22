import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// The Lists tab: every list that the session's user can edit. Their own lists, the primary list first and then the
/// extra lists by name, and then a part for each child. See "Tabs that become a sidebar" and "A deactivated child"
/// in `docs/spec.md`, and `docs/screens/lists.md`.
@Suite("The Lists tab", .timeLimit(.minutes(1)))
@MainActor
struct ListsTabTests {
  /// A new device, signed in as the person, once a sync has filled its copy. Each device has a keychain of its own,
  /// so a test can sign several people in on one server.
  private func signedIn(as person: Fixture.Person, on instance: Instance) async throws -> SessionModel {
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    #expect(await session.syncNow() == .succeeded)
    return session
  }

  @Test("The user's own lists: the primary list first, then the extra lists by name")
  func yourLists() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let zebra = try await builder.list("Zebra", of: family.parent)
    let aardvark = try await builder.list("Aardvark", of: family.parent)
    let primary = try await builder.primaryList(of: family.parent)

    let session = try await signedIn(as: family.parent, on: instance)
    #expect(
      session.listsTab.yourLists.map(\.id) == [primary.id, aardvark.id, family.parentList.id, zebra.id])
  }

  @Test("One part for each child. A list shared with the child shows once, under the user's own")
  func childParts() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    try await builder.accept(try await builder.invite(family.child, to: family.parentList, as: family.parent))
    let childPrimary = try await builder.primaryList(of: family.child)
    let books = try await builder.list("Books", of: family.child)

    let session = try await signedIn(as: family.parent, on: instance)
    let tab = session.listsTab
    #expect(Set(tab.children.map(\.id)) == [family.child.id, family.deactivatedChild.id])
    #expect(tab.yourLists.contains { $0.id == family.parentList.id })

    let part = try #require(tab.children.first { $0.id == family.child.id })
    #expect(part.child.name == family.child.name)
    #expect(!part.child.isDeactivated)
    // The list that the child shares with their sibling shows in the child's part too.
    #expect(part.lists.map(\.id) == [childPrimary.id, books.id, family.sharedList.id])
    #expect(!tab.children.flatMap(\.lists).contains { $0.id == family.parentList.id })
  }

  @Test("The deactivated child's part is there, with its lists")
  func deactivatedChild() async throws {
    let instance = try await Instance()
    let family = try await instance.builder.standardFamily()

    let session = try await signedIn(as: family.parent, on: instance)
    let part = try #require(session.listsTab.children.first { $0.id == family.deactivatedChild.id })
    #expect(part.child.isDeactivated)
    #expect(part.lists.map(\.id) == [family.primaryList.id, family.extraList.id, family.sharedList.id])
  }

  @Test("A row has the server's item_count")
  func itemCount() async throws {
    let instance = try await Instance()
    let family = try await instance.builder.standardFamily()

    let session = try await signedIn(as: family.parent, on: instance)
    let part = try #require(session.listsTab.children.first { $0.id == family.deactivatedChild.id })
    for list in part.lists {
      let served = try await family.parent.signedIn().get("/lists/\(list.id)")["item_count"].number
      #expect(served.map(Int.init) == list.itemCount)
    }
    // The kite is wanted, and the puzzle was given and left the list.
    #expect(part.lists.first { $0.id == family.primaryList.id }?.itemCount == 1)
    #expect(part.lists.first { $0.id == family.extraList.id }?.itemCount == 1)
  }

  @Test("After the first sync, the tab always has a row, even for a user with no group and no child")
  func alwaysARow() async throws {
    let instance = try await Instance()
    let family = try await instance.builder.standardFamily()

    for person in [family.outsider, family.child, family.relative, family.parent] {
      let session = try await signedIn(as: person, on: instance)
      #expect(!session.listsTab.isEmpty)
      #expect(session.screenState(hasRows: !session.listsTab.isEmpty) == .saved(cantReach: false))
    }
    let outsider = try await signedIn(as: family.outsider, on: instance)
    #expect(outsider.listsTab.yourLists.count == 1)
    #expect(outsider.listsTab.children.isEmpty)
  }
}
