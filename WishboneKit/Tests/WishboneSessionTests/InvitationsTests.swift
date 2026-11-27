import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// Accept and Decline, on the Lists tab and on the list's page, at the session model's seam, against the real
/// server. Each is an unsent change, with no confirmation: it shows at once, in every window, and reaches the server.
/// See "Invitations", "Accept" and "Decline" in `docs/screens/lists.md` and `docs/screens/list.md`, and in
/// `docs/spec.md`: "Unsent changes", "A deactivated child", and "The rest, as the server has it".
@Suite("Accepting and declining an invitation", .timeLimit(.minutes(2)))
@MainActor
final class InvitationsTests {
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

  /// A family for these tests: Mom, the user, and the user's child, in one group. Mom has two extra lists, "Our
  /// house" and "Cousins", that nobody else is on.
  private struct Family {
    let mom: Fixture.Person
    let me: Fixture.Person
    let child: Fixture.Person
    let ourHouse: Fixture.List
    let cousins: Fixture.List
  }

  private func family() async throws -> Family {
    let builder = instance.builder
    let mom = try await builder.person("Mom")
    let me = try await builder.person("Avery")
    let child = try await builder.person("Emma", parents: [me])
    _ = try await builder.group("Home", users: [mom, me, child])
    return Family(
      mom: mom, me: me, child: child, ourHouse: try await builder.list("Our house", of: mom),
      cousins: try await builder.list("Cousins", of: mom))
  }

  /// The IDs of the list's recipients, as the person reads them from the server.
  private func recipients(of list: Fixture.List, as person: Fixture.Person) async throws -> [String] {
    let rows = try await person.signedIn().get("/lists/\(list.id)/recipients")["data"].array ?? []
    return rows.compactMap { $0["user"]["id"].string }
  }

  @Test(
    """
    Invitations show only while one is pending: the user's own, and their child's, each with who invited whom. \
    An invitation to someone else on a list of the user's doesn't show
    """
  )
  func pendingInvitations() async throws {
    let builder = instance.builder
    let family = try await family()
    let mine = try await builder.list("Trip", of: family.me)
    let session = try await signedIn(as: family.me)
    #expect(session.listsTab.invitations.isEmpty)

    let toMe = try await builder.invite(family.me, to: family.ourHouse, as: family.mom)
    let toChild = try await builder.invite(family.child, to: family.cousins, as: family.mom)
    _ = try await builder.invite(family.mom, to: mine, as: family.me)
    await session.syncNow()
    try await untilInStep(session, as: family.me)

    // Both, and only them. Two made in the same second are in the copy's order, by ID as text.
    let invitations = session.listsTab.invitations
    #expect(Set(invitations.map(\.id)) == [toMe.id, toChild.id])
    let first = try #require(invitations.first { $0.id == toMe.id })
    #expect(first.invited == .you)
    #expect(first.inviterName == family.mom.name)
    #expect(first.row.listName == family.ourHouse.name)
    #expect(first.canAccept)
    #expect(first.canDecline)
    // The user sees Mom, so they see her lists: a tap on the line opens the list's page.
    #expect(first.opensList)
    let second = try #require(invitations.first { $0.id == toChild.id })
    #expect(second.invited == .child(name: family.child.name))
    #expect(second.inviterName == family.mom.name)
    #expect(second.row.listName == family.cousins.name)
    #expect(second.canAccept)
    #expect(second.canDecline)

    // The same invitation is at the top of the list's page, and only there.
    #expect(session.pendingInvitations(toList: family.ourHouse.id).map(\.id) == [toMe.id])
    #expect(session.pendingInvitations(toList: family.cousins.id).map(\.id) == [toChild.id])
    #expect(session.pendingInvitations(toList: mine.id).isEmpty)
  }

  @Test("Accept moves the list into the user's own lists at once, and the server has the user as a recipient")
  func accept() async throws {
    let builder = instance.builder
    let family = try await family()
    let lamp = try await builder.item("Lamp", on: family.ourHouse, as: family.mom)
    let invitation = try await builder.invite(family.me, to: family.ourHouse, as: family.mom)
    let session = try await signedIn(as: family.me)
    #expect(!session.listsTab.yourLists.map(\.id).contains(family.ourHouse.id))
    #expect(session.listPage(id: family.ourHouse.id)?.isRecipient == false)
    #expect(session.itemPage(id: lamp.id)?.stillWanted != nil)
    #expect(session.itemPage(id: lamp.id)?.offersClaim == true)
    #expect(session.offersClaim(onItem: lamp.id))

    await session.acceptInvitation(invitation.id)

    // At once: the invitation is gone, and the list is among the user's own, with them as a recipient. Its page
    // shows the list as a recipient sees it, with no claim state.
    #expect(session.listsTab.invitations.isEmpty)
    #expect(session.listsTab.yourLists.map(\.id).contains(family.ourHouse.id))
    let page = try #require(session.listPage(id: family.ourHouse.id))
    #expect(page.isRecipient)
    #expect(page.items.allSatisfy { $0.claim == nil })
    // The Lamp's row is still the giver's row until the next pull, but its page and its row offer no claim state.
    #expect(session.itemPage(id: lamp.id)?.stillWanted == nil)
    #expect(session.itemPage(id: lamp.id)?.offersClaim == false)
    #expect(session.offersClaim(onItem: lamp.id) == false)

    await until { session.unsentChangeCount == 0 }
    #expect(try await recipients(of: family.ourHouse, as: family.mom).contains(family.me.id))
    #expect(try await family.me.signedIn().status(of: "/invitations/\(invitation.id)") == 404)
    try await untilInStep(session, as: family.me)
    #expect(session.listsTab.yourLists.map(\.id).contains(family.ourHouse.id))
    #expect(session.listsTab.invitations.isEmpty)
    #expect(session.lateRefusals.isEmpty)
  }

  @Test("A giver who accepts sees no claim of their own on the list's items, and no Get another, before the next pull")
  func acceptWithAGift() async throws {
    let builder = instance.builder
    let family = try await family()
    let lamp = try await builder.item("Lamp", on: family.ourHouse, as: family.mom, quantity: 3)
    let recital = try await builder.customOccasion("Recital", of: family.mom, year: 2040, month: 6, day: 1)
    // Another occasion, so that Get another shows. On the shared server, an occasion for everyone can come sooner.
    _ = try await builder.customOccasion("Graduation", of: family.mom, year: 2039, month: 1, day: 1)
    let gift = try await builder.claim(lamp, as: family.me, for: recital)
    let invitation = try await builder.invite(family.me, to: family.ourHouse, as: family.mom)
    let session = try await signedIn(as: family.me)
    await until { session.anotherOccasion(forGift: gift.id) != nil }
    #expect(session.itemPage(id: lamp.id)?.claims.map(\.id) == [gift.id])
    #expect(session.giftPage(id: gift.id)?.offersRaise == true)

    await session.acceptInvitation(invitation.id)

    // At once, while the Lamp's row and the gift are still the giver's until the next pull.
    #expect(session.listPage(id: family.ourHouse.id)?.isRecipient == true)
    #expect(session.itemPage(id: lamp.id)?.claims == [])
    #expect(session.anotherOccasion(forGift: gift.id) == nil)
    // Once the giver is a recipient, how many can only go down.
    #expect(session.giftPage(id: gift.id)?.offersRaise == false)
    #expect(await session.raiseQuantity(gift: gift.id) == .notOffered)
    #expect(session.gift(id: gift.id)?.quantity == 1)
    await until { session.unsentChangeCount == 0 }
    #expect(session.lateRefusals.isEmpty)
  }

  @Test("Accept for a child moves the list into the child's part")
  func acceptForChild() async throws {
    let builder = instance.builder
    let family = try await family()
    let invitation = try await builder.invite(family.child, to: family.cousins, as: family.mom)
    let session = try await signedIn(as: family.me)
    let part = { session.listsTab.children.first { $0.child.id == family.child.id } }
    #expect(part()?.lists.map(\.id).contains(family.cousins.id) == false)

    await session.acceptInvitation(invitation.id)

    #expect(session.listsTab.invitations.isEmpty)
    #expect(part()?.lists.map(\.id).contains(family.cousins.id) == true)
    #expect(!session.listsTab.yourLists.map(\.id).contains(family.cousins.id))

    await until { session.unsentChangeCount == 0 }
    #expect(try await recipients(of: family.cousins, as: family.mom).contains(family.child.id))
    try await untilInStep(session, as: family.me)
    #expect(part()?.lists.map(\.id).contains(family.cousins.id) == true)
    #expect(session.lateRefusals.isEmpty)
  }

  @Test("Decline takes the invitation out at once, and the server no longer has it")
  func decline() async throws {
    let builder = instance.builder
    let family = try await family()
    let toMe = try await builder.invite(family.me, to: family.ourHouse, as: family.mom)
    let toChild = try await builder.invite(family.child, to: family.cousins, as: family.mom)
    let session = try await signedIn(as: family.me)
    #expect(session.listsTab.invitations.count == 2)

    await session.declineInvitation(toChild.id)
    #expect(session.listsTab.invitations.map(\.id) == [toMe.id])
    #expect(session.pendingInvitations(toList: family.cousins.id).isEmpty)

    await session.declineInvitation(toMe.id)
    #expect(session.listsTab.invitations.isEmpty)

    await until { session.unsentChangeCount == 0 }
    #expect(try await family.mom.signedIn().status(of: "/invitations/\(toMe.id)") == 404)
    #expect(try await family.mom.signedIn().status(of: "/invitations/\(toChild.id)") == 404)
    #expect(try await recipients(of: family.ourHouse, as: family.mom) == [family.mom.id])
    #expect(try await recipients(of: family.cousins, as: family.mom) == [family.mom.id])
    try await untilInStep(session, as: family.me)
    #expect(session.listsTab.invitations.isEmpty)
    #expect(!session.listsTab.yourLists.map(\.id).contains(family.ourHouse.id))
    #expect(session.lateRefusals.isEmpty)
  }

  @Test("A deactivated child's invitation shows with no Accept, and Accept does nothing for it")
  func deactivatedChild() async throws {
    let family = try await instance.builder.standardFamily()
    let session = try await signedIn(as: family.parent)

    let invitation = try #require(session.listsTab.invitations.first { $0.id == family.pendingInvitation.id })
    #expect(invitation.invited == .child(name: family.deactivatedChild.name))
    #expect(!invitation.canAccept)
    #expect(!invitation.row.canAccept)
    #expect(session.pendingInvitations(toList: family.parentList.id).map(\.id) == [family.pendingInvitation.id])

    await session.acceptInvitation(invitation.id)
    #expect(session.unsentChangeCount == 0)
    #expect(session.listsTab.invitations.contains { $0.id == family.pendingInvitation.id })
  }

  @Test("An accept made with the network dropped shows at once, and is sent when the instance answers")
  func acceptOffline() async throws {
    let builder = instance.builder
    let family = try await family()
    let invitation = try await builder.invite(family.me, to: family.ourHouse, as: family.mom)
    let session = try await signedIn(as: family.me, on: instance)

    instance.conditioner.dropEverything()
    await session.acceptInvitation(invitation.id)
    await until { session.isInstanceUnreachable }
    #expect(session.unsentChangeCount == 1)
    #expect(session.listsTab.invitations.isEmpty)
    #expect(session.listsTab.yourLists.map(\.id).contains(family.ourHouse.id))
    #expect(try await recipients(of: family.ourHouse, as: family.mom) == [family.mom.id])

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    #expect(try await recipients(of: family.ourHouse, as: family.mom).contains(family.me.id))
    #expect(session.listsTab.yourLists.map(\.id).contains(family.ourHouse.id))
    #expect(session.lateRefusals.isEmpty)
  }

  @Test(
    """
    An accept that the server refuses, because the child was deactivated meanwhile, brings the invitation back, \
    shows once, and is captured by its route and code
    """
  )
  func acceptRefused() async throws {
    let builder = instance.builder
    let family = try await family()
    let invitation = try await builder.invite(family.child, to: family.cousins, as: family.mom)
    let diagnostics = RecordingDiagnostics()
    let session = try await signedIn(as: family.me, on: instance, diagnostics: diagnostics)

    instance.conditioner.dropEverything()
    await session.acceptInvitation(invitation.id)
    await until { session.isInstanceUnreachable }
    #expect(session.listsTab.invitations.isEmpty)
    _ = try await builder.deactivate(family.child)

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    await until { session.lateRefusals.count == 1 }
    #expect(diagnostics.faults == [.refusedWrite(.acceptInvitation, code: "user_deactivated")])
    #expect(try await recipients(of: family.cousins, as: family.mom) == [family.mom.id])

    // Rolled back: the invitation is back, now with no Accept, and the list isn't in the child's part.
    await until { session.listsTab.invitations.map(\.id) == [invitation.id] }
    #expect(session.listsTab.invitations.first?.canAccept == false)
    let part = session.listsTab.children.first { $0.child.id == family.child.id }
    #expect(part?.lists.map(\.id).contains(family.cousins.id) != true)

    await session.cameToForeground(window: UUID())
    let refusal = try #require(session.lateRefusalAlert?.refusals.first)
    #expect(refusal.title == family.cousins.name)
    #expect(refusal.refusal.code == .userDeactivated)
  }
}
