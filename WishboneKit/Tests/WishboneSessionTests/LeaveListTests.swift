import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// Leave, and Make {child} leave, on a list's page, at the session model's seam, against the real server. Each
/// waits for the server, and the warning shows by the server's own rule. See `docs/screens/list.md`, and in
/// `docs/spec.md`: "Other writes that wait for the server", and "The rest, as the server has it".
@Suite("Leaving a list", .timeLimit(.minutes(2)))
@MainActor
final class LeaveListTests {
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

  /// The standard family, with the active child invited to the parent's list "Our house", and an item on it that
  /// the relative claimed. The child and the parent share the household, so each would still see the list.
  private func sharedWithChild() async throws -> (StandardFamily, Fixture.List) {
    let builder = instance.builder
    let family = try await builder.standardFamily()
    try await builder.accept(try await builder.invite(family.child, to: family.parentList, as: family.parent))
    let item = try await builder.item("Lamp", on: family.parentList, as: family.parent, quantity: 2)
    _ = try await builder.claim(item, as: family.relative, for: family.groupOccasion)
    return (family, family.parentList)
  }

  /// The IDs of the list's recipients, as the person reads them from the server.
  private func recipientsOnServer(of list: Fixture.List, as person: Fixture.Person) async throws -> [String] {
    try await person.signedIn().all("/lists/\(list.id)/recipients").compactMap { $0["user"]["id"].string }
  }

  @Test("Leave takes the list out of the user's lists after the server answers, and shows it as a giver sees it")
  func leave() async throws {
    let (family, list) = try await sharedWithChild()
    let child = try await signedIn(as: family.child)
    let page = try #require(child.listPage(id: list.id))
    #expect(page.isRecipient)
    #expect(child.listsTab.yourLists.map(\.id).contains(list.id))
    let leave = try #require(page.leave)
    #expect(leave.user.id == family.child.id)
    #expect(leave.isSessionUser)
    #expect(page.makeLeave.isEmpty)

    #expect(await child.leave(list: list.id, as: leave) == .left)

    #expect(try await recipientsOnServer(of: list, as: family.parent) == [family.parent.id])
    await until { child.listPage(id: list.id)?.isRecipient == false }
    #expect(!child.listsTab.yourLists.map(\.id).contains(list.id))
    let after = try #require(child.listPage(id: list.id))
    #expect(after.leave == nil)
    #expect(after.recipients.map(\.user.id) == [family.parent.id])
    // A giver sees how many are still wanted, and who claimed is never said.
    #expect(after.items.map(\.claim) == [UserPage.Claim(stillWanted: 1, quantity: 2, youClaimed: 0)])
  }

  @Test("A list that the user can't see after they leave goes from the copy")
  func leaveAndLoseSight() async throws {
    let builder = instance.builder
    let owner = try await builder.person("Avery")
    let guest = try await builder.person("Blake")
    let pair = try await builder.group("Pair", users: [owner, guest])
    let list = try await builder.list("Trip", of: owner)
    try await builder.accept(try await builder.invite(guest, to: list, as: owner))
    // The guest no longer shares a group with the owner: only being a recipient shows them the list.
    _ = try await builder.admin.signedIn().send("DELETE", "/groups/\(pair.id)/users/\(guest.id)").expecting(204)

    let session = try await signedIn(as: guest)
    let leave = try #require(session.listPage(id: list.id)?.leave)
    #expect(!leave.seesListAfterLeaving)
    #expect(await session.leave(list: list.id, as: leave) == .left)
    await until { session.listPage(id: list.id) == nil }
  }

  @Test("The warning shows exactly when the leaver's row has sees_list_after_leaving")
  func warning() async throws {
    let (family, list) = try await sharedWithChild()

    // The child shares the household with the parent, so they would still see the list.
    let child = try await signedIn(as: family.child)
    #expect(try #require(child.listPage(id: list.id)?.leave).seesListAfterLeaving)

    // The child's own row says the same, and the page follows each row of the copy, whatever it says.
    for session in [child, try await signedIn(as: family.parent)] {
      let page = try #require(session.listPage(id: list.id))
      for leaver in [page.leave].compactMap(\.self) + page.makeLeave {
        let row = try #require(session.recipients(ofList: list.id).first { $0.userID == leaver.user.id })
        #expect(leaver.seesListAfterLeaving == (row.seesListAfterLeaving == .shown(true)))
      }
    }

    // A user who sees the list only as its recipient gets no warning.
    let builder = instance.builder
    let owner = try await builder.person("Avery")
    let guest = try await builder.person("Blake")
    let pair = try await builder.group("Pair", users: [owner, guest])
    let trip = try await builder.list("Trip", of: owner)
    try await builder.accept(try await builder.invite(guest, to: trip, as: owner))
    _ = try await builder.admin.signedIn().send("DELETE", "/groups/\(pair.id)/users/\(guest.id)").expecting(204)
    let alone = try await signedIn(as: guest)
    let row = try #require(alone.recipients(ofList: trip.id).first { $0.userID == guest.id })
    #expect(row.seesListAfterLeaving == .shown(false))
    #expect(try #require(alone.listPage(id: trip.id)?.leave).seesListAfterLeaving == false)
  }

  @Test("Make {child} leave shows for each child whose row has can_delete, with the warning about the child")
  func makeChildLeave() async throws {
    let (family, list) = try await sharedWithChild()
    let parent = try await signedIn(as: family.parent)

    // On their own list, the parent can leave, and can make the child leave.
    let page = try #require(parent.listPage(id: list.id))
    #expect(page.leave?.user.id == family.parent.id)
    let makeLeave = try #require(page.makeLeave.first)
    #expect(page.makeLeave.map(\.user.id) == [family.child.id])
    #expect(!makeLeave.isSessionUser)
    #expect(makeLeave.user.name == family.child.name)
    #expect(makeLeave.seesListAfterLeaving)

    // On the children's shared list, which the parent is not on: the active child only. The deactivated child's
    // row has no can_delete, because the parent can't act for them.
    let shared = try #require(parent.listPage(id: family.sharedList.id))
    #expect(shared.leave == nil)
    #expect(shared.makeLeave.map(\.user.id) == [family.child.id])
    #expect(
      parent.recipients(ofList: family.sharedList.id).first { $0.userID == family.deactivatedChild.id }?.canDelete
        == false)

    // Nobody else's child: the relative sees the list, and leaves no one.
    let relative = try await signedIn(as: family.relative)
    let asRelative = try #require(relative.listPage(id: list.id))
    #expect(asRelative.leave == nil)
    #expect(asRelative.makeLeave.isEmpty)

    #expect(await parent.leave(list: list.id, as: makeLeave) == .left)
    #expect(try await recipientsOnServer(of: list, as: family.parent) == [family.parent.id])
    // The list row, which names the recipients, is saved after the recipient rows, which Make {child} leave reads.
    try await untilInStep(parent, as: family.parent)
    let after = try #require(parent.listPage(id: list.id))
    #expect(after.recipients.map(\.user.id) == [family.parent.id])
    #expect(after.makeLeave.isEmpty)
  }

  @Test("With the network dropped, Leave says the instance can't be reached, changes nothing, and queues nothing")
  func offline() async throws {
    let (family, list) = try await sharedWithChild()
    let child = try await signedIn(as: family.child, on: instance)
    let before = try #require(child.listPage(id: list.id))
    let leave = try #require(before.leave)

    instance.conditioner.dropEverything()
    #expect(await child.leave(list: list.id, as: leave) == .unreachable)
    #expect(child.listPage(id: list.id) == before)

    // Nothing waits to be sent: with the network back, a sync leaves the child on the list.
    instance.conditioner.passEverything()
    await child.syncNow()
    #expect(try await recipientsOnServer(of: list, as: family.parent) == [family.parent.id, family.child.id])
    try await untilInStep(child, as: family.child)
    #expect(child.listPage(id: list.id)?.isRecipient == true)
  }

  @Test("A refusal with last_recipient comes back with its code, is not captured, and changes nothing")
  func lastRecipient() async throws {
    let (family, list) = try await sharedWithChild()
    let diagnostics = RecordingDiagnostics()
    let child = try await signedIn(as: family.child, diagnostics: diagnostics)
    let before = try #require(child.listPage(id: list.id))
    let leave = try #require(before.leave)
    // The parent leaves elsewhere, so the child is the only recipient now. The copy doesn't know it yet.
    _ = try await family.parent.signedIn().send("DELETE", "/lists/\(list.id)/recipients/\(family.parent.id)")
      .expecting(204)

    let outcome = await child.leave(list: list.id, as: leave)
    guard case .refused(let refusal) = outcome else {
      Issue.record("The last recipient's leave was not refused: \(outcome)")
      return
    }
    #expect(refusal.status == 403)
    #expect(refusal.code == .lastRecipient)
    #expect(child.listPage(id: list.id) == before)
    #expect(diagnostics.faults.isEmpty)
  }
}
