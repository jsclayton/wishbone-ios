import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// Edit list, and Delete list, on a list's page, at the session model's seam, against the real server. Each is an
/// unsent change: it shows at once, in every window, and reaches the server. See "Edit list" and "Delete list" in
/// `docs/screens/list.md`, and in `docs/spec.md`: "Unsent changes", "A page that goes away under a window", and
/// "The rest, as the server has it".
@Suite("Editing and deleting a list", .timeLimit(.minutes(2)))
@MainActor
final class ListEditsTests {
  let instance: Instance

  /// The instances of the devices that the test signed in, kept for the whole test: each one's conditioner is the
  /// way to the server for its device.
  private var others: [Instance] = []

  init() async throws {
    instance = try await Instance()
  }

  /// A device signed in as the person, with the first sync over. A test that drops the network uses this test's own
  /// instance: its device goes through that conditioner. Otherwise the person signs in on another instance of the
  /// same server, because a device on the same one shares its session keychain.
  private func signedIn(
    as person: Fixture.Person, on instance: Instance? = nil, diagnostics: RecordingDiagnostics? = nil
  ) async throws -> SessionModel {
    let instance = if let instance { instance } else { try await Instance(server: self.instance.server) }
    others.append(instance)
    let device = diagnostics.map { instance.device(diagnostics: $0) } ?? instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    try await untilInStep(session, as: person)
    return session
  }

  /// The list as the person reads it from the server.
  private func onServer(_ list: Fixture.List, as person: Fixture.Person) async throws -> JSON {
    try await person.signedIn().get("/lists/\(list.id)")
  }

  @Test("A new name and a new description show at once, and reach the server")
  func edit() async throws {
    let builder = instance.builder
    let owner = try await builder.person("Avery")
    let list = try await builder.list("Trip", of: owner)
    let session = try await signedIn(as: owner)
    #expect(session.list(id: list.id)?.canEdit == true)

    await session.editList(list.id, name: "  Road trip  ", description: "Things for the **car**.")

    // At once, before the server has it: the page, and the user's lists, show the new name.
    let page = try #require(session.listPage(id: list.id))
    #expect(page.list.name == "Road trip")
    #expect(page.list.description == "Things for the **car**.")
    #expect(session.listsTab.yourLists.first { $0.id == list.id }?.name == "Road trip")

    await until { session.unsentChangeCount == 0 }
    let answer = try await onServer(list, as: owner)
    #expect(answer["name"].string == "Road trip")
    #expect(answer["description"].string == "Things for the **car**.")
    await until { session.list(id: list.id)?.name == "Road trip" }

    // A blank description clears it, and only the description is sent.
    await session.editList(list.id, name: "Road trip", description: "  ")
    #expect(session.list(id: list.id)?.description == nil)
    await until { session.unsentChangeCount == 0 }
    #expect(try await onServer(list, as: owner)["description"].isNull)
    #expect(try await onServer(list, as: owner)["name"].string == "Road trip")

    // An edit that changes nothing, or a blank name, saves nothing.
    await session.editList(list.id, name: "  ", description: "")
    #expect(session.unsentChangeCount == 0)
    #expect(session.list(id: list.id)?.name == "Road trip")
  }

  @Test("A rename that waits offline shows in every window, and reaches the server when it is back")
  func editOffline() async throws {
    let builder = instance.builder
    let owner = try await builder.person("Avery")
    let list = try await builder.list("Trip", of: owner)
    let session = try await signedIn(as: owner, on: instance)

    instance.conditioner.dropEverything()
    await session.editList(list.id, name: "Road trip", description: "")
    await until { session.isInstanceUnreachable }
    #expect(session.unsentChangeCount == 1)
    #expect(session.listPage(id: list.id)?.list.name == "Road trip")

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    #expect(try await onServer(list, as: owner)["name"].string == "Road trip")
    #expect(session.list(id: list.id)?.name == "Road trip")
  }

  @Test("Delete takes the list out of Lists at once, and a window that shows its page shows not found")
  func delete() async throws {
    let builder = instance.builder
    let owner = try await builder.person("Avery")
    let list = try await builder.list("Trip", of: owner)
    _ = try await builder.item("Map", on: list, as: owner)
    let session = try await signedIn(as: owner, on: instance)
    #expect(session.listPage(id: list.id)?.canDelete == true)

    // Offline, so that what shows at once can't be the server's.
    instance.conditioner.dropEverything()
    await session.deleteList(list.id)

    // Every window reads the one copy: the list's page is the "not found" page, and Lists no longer has it.
    #expect(session.listPage(id: list.id) == nil)
    #expect(session.items(onList: list.id).isEmpty)
    #expect(!session.listsTab.yourLists.map(\.id).contains(list.id))
    #expect(session.unsentChangeCount == 1)

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    #expect(try await owner.signedIn().status(of: "/lists/\(list.id)") == 404)
    #expect(session.listPage(id: list.id) == nil)
    #expect(session.lateRefusals.isEmpty)
  }

  @Test("Delete shows only from can_delete, and never on a primary list")
  func deleteShowsOnlyFromCanDelete() async throws {
    let builder = instance.builder
    let owner = try await builder.person("Avery")
    let guest = try await builder.person("Blake")
    _ = try await builder.group("Pair", users: [owner, guest])
    let alone = try await builder.list("Trip", of: owner)
    let shared = try await builder.list("House", of: owner)
    try await builder.accept(try await builder.invite(guest, to: shared, as: owner))
    let primary = try await builder.primaryList(of: owner)

    let session = try await signedIn(as: owner)
    #expect(try #require(session.listPage(id: alone.id)).canDelete)
    // A list with another recipient has can_delete false: it can only be left.
    #expect(session.list(id: shared.id)?.canDelete == false)
    #expect(try #require(session.listPage(id: shared.id)).canDelete == false)
    // The primary list is never deleted, and Delete never shows on it.
    let primaryPage = try #require(session.listPage(id: primary.id))
    #expect(primaryPage.list.isPrimary)
    #expect(!primaryPage.canDelete)

    // A giver, who can't edit the list, sees no Delete either.
    let giver = try await signedIn(as: guest)
    #expect(try #require(giver.listPage(id: alone.id)).canDelete == false)

    // And deleteList does nothing for any of them.
    await session.deleteList(shared.id)
    await session.deleteList(primary.id)
    await giver.deleteList(alone.id)
    #expect(session.unsentChangeCount == 0)
    #expect(giver.unsentChangeCount == 0)
    #expect(session.listPage(id: shared.id) != nil)
    #expect(session.listPage(id: primary.id) != nil)
  }

  @Test(
    """
    A delete that the server refuses with list_has_other_recipients brings the list back, shows once with its \
    code, and is captured by its route and code
    """
  )
  func deleteRefused() async throws {
    let builder = instance.builder
    let owner = try await builder.person("Avery")
    let guest = try await builder.person("Blake")
    _ = try await builder.group("Pair", users: [owner, guest])
    let list = try await builder.list("Trip", of: owner)
    _ = try await builder.item("Map", on: list, as: owner)
    let invitation = try await builder.invite(guest, to: list, as: owner)
    let diagnostics = RecordingDiagnostics()
    let session = try await signedIn(as: owner, on: instance, diagnostics: diagnostics)

    // Offline, the owner deletes the list. Meanwhile, the guest accepts the invitation from another device.
    instance.conditioner.dropEverything()
    await session.deleteList(list.id)
    await until { session.isInstanceUnreachable }
    #expect(session.listPage(id: list.id) == nil)
    try await builder.accept(invitation)

    instance.conditioner.passEverything()
    await session.syncNow()

    // Rolled back: the list, and its item, are back, with both recipients.
    await until { session.unsentChangeCount == 0 }
    await until { session.listPage(id: list.id)?.recipients.count == 2 }
    #expect(session.items(onList: list.id).count == 1)
    #expect(try await owner.signedIn().status(of: "/lists/\(list.id)") == 200)
    await until { session.lateRefusals.count == 1 }
    #expect(diagnostics.faults == [.refusedWrite(.deleteList, code: "list_has_other_recipients")])

    let window = UUID()
    await session.cameToForeground(window: window)
    let refusal = try #require(session.lateRefusalAlert?.refusals.first)
    #expect(refusal.action == .deleteList(listID: list.id))
    #expect(refusal.title == list.name)
    #expect(refusal.refusal.code == .listHasOtherRecipients)
    #expect(refusal.refusal.status == 403)
  }

  @Test("A parent renames and deletes their child's extra list")
  func parentDeletesChildsList() async throws {
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.list("Toys", of: family.child)
    let parent = try await signedIn(as: family.parent)

    let page = try #require(parent.listPage(id: list.id))
    #expect(!page.isRecipient)
    #expect(page.list.canEdit)
    #expect(page.canDelete)

    await parent.editList(list.id, name: "Robin's toys", description: "")
    #expect(parent.list(id: list.id)?.name == "Robin's toys")
    await until { parent.unsentChangeCount == 0 }
    #expect(try await onServer(list, as: family.child)["name"].string == "Robin's toys")

    await parent.deleteList(list.id)
    #expect(parent.listPage(id: list.id) == nil)
    await until { parent.unsentChangeCount == 0 }
    #expect(try await family.child.signedIn().status(of: "/lists/\(list.id)") == 404)
    #expect(parent.lateRefusals.isEmpty)
  }
}
