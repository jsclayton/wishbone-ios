import Foundation
import GRDB
import TestSupport
import Testing
import WishboneAPI

@testable import WishboneSession

/// Invite and Withdraw, on a list's page, at the session model's seam, against the real server. Each is an unsent
/// change, with no confirmation: it shows at once, in every window, and reaches the server. Who can be invited comes
/// from the copy, by the server's rule for `?invitable_to=`. See Invite and Withdraw in `docs/screens/list.md`, and
/// "Unsent changes" in `docs/spec.md`.
@Suite("Inviting to a list, and withdrawing an invitation", .timeLimit(.minutes(2)))
@MainActor
final class InviteTests {
  typealias Route = NetworkConditioner.Route

  static let createInvitation = Route("POST", "/lists/{id}/invitations")
  static let withdraw = Route("DELETE", "/invitations/{id}")
  static let createList = Route("POST", "/lists")

  let instance: Instance

  /// The one window of the app, as it comes to the foreground.
  let window = UUID()

  /// The devices that the test signed in, and their instances, kept for the whole test.
  private var devices: [Device] = []
  private var others: [Instance] = []

  init() async throws {
    instance = try await Instance()
  }

  /// A device signed in as the person, with the copy in step with the instance. It goes through `instance`, this
  /// test's own by default, whose conditioner is the way to the server.
  private func signedIn(
    as person: Fixture.Person, on instance: Instance? = nil, diagnostics: any DiagnosticsReporter = .none
  ) async throws -> SessionModel {
    let instance = instance ?? self.instance
    others.append(instance)
    let device = instance.device(diagnostics: diagnostics)
    devices.append(device)
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    try await untilInStep(session, as: person)
    return session
  }

  /// A family for these tests: Mom, the user, in a group with Grandpa and Dad, and Mom's child Emma. Mom has an
  /// extra list, "Our house", that nobody else is on. A stranger shares no group with anyone.
  private struct Family {
    let me: Fixture.Person
    let grandpa: Fixture.Person
    let dad: Fixture.Person
    let emma: Fixture.Person
    let stranger: Fixture.Person
    let ourHouse: Fixture.List
  }

  private func family(on instance: Instance? = nil) async throws -> Family {
    let builder = (instance ?? self.instance).builder
    let me = try await builder.person("Mom")
    let grandpa = try await builder.person("Grandpa")
    let dad = try await builder.person("Dad")
    let emma = try await builder.person("Emma", parents: [me])
    let stranger = try await builder.person("Stranger")
    _ = try await builder.group("Home", users: [me, grandpa, dad])
    return Family(
      me: me, grandpa: grandpa, dad: dad, emma: emma, stranger: stranger,
      ourHouse: try await builder.list("Our house", of: me))
  }

  /// The IDs of the users whom the person can invite to the list, as the server says: `GET /users?invitable_to=`.
  private func invitable(to list: Fixture.List, as person: Fixture.Person) async throws -> [String] {
    try await person.signedIn().all("/users?invitable_to=\(list.id)").compactMap { $0["id"].string }
  }

  /// The pending invitations to the list, as the person reads them from the server.
  private func invitations(to list: Fixture.List, as person: Fixture.Person) async throws -> [JSON] {
    try await person.signedIn().all("/invitations?list_id=\(list.id)")
  }

  private var requests: [NetworkConditioner.SeenRequest] {
    instance.conditioner.requests
  }

  // MARK: - 1. The sheet's users are the server's

  @Test(
    """
    The sheet's users are the server's invitable_to for a recipient: the people they see, active, not on the list, \
    and with no invitation to it. After an invite, they still are
    """
  )
  func sheetIsTheServers() async throws {
    let builder = instance.builder
    let family = try await family()
    // A deactivated child, a user invited already, and a recipient: none of them can be invited.
    let leo = try await builder.person("Leo", parents: [family.me])
    _ = try await builder.deactivate(leo)
    let aunt = try await builder.person("Aunt")
    let uncle = try await builder.person("Uncle")
    _ = try await builder.group("Cousins", users: [family.me, aunt, uncle])
    _ = try await builder.invite(aunt, to: family.ourHouse, as: family.me)
    try await builder.accept(try await builder.invite(uncle, to: family.ourHouse, as: family.me))
    let session = try await signedIn(as: family.me)
    // The user sees Leo, as his parent, and Aunt and Uncle: the rule, not the copy, leaves them out.
    #expect(session.user(id: leo.id)?.isDeactivated == true)
    #expect(session.user(id: aunt.id)?.isSummary == false)

    let server = try await invitable(to: family.ourHouse, as: family.me)
    #expect(Set(server) == [family.grandpa.id, family.dad.id, family.emma.id])
    #expect(session.invitableUsers(toList: family.ourHouse.id).map(\.id) == server)

    await session.invite(family.grandpa.id, toList: family.ourHouse.id)
    await until { session.unsentChangeCount == 0 }
    try await untilInStep(session, as: family.me)
    let after = try await invitable(to: family.ourHouse, as: family.me)
    #expect(Set(after) == [family.dad.id, family.emma.id])
    #expect(session.invitableUsers(toList: family.ourHouse.id).map(\.id) == after)
  }

  @Test(
    """
    For the admin as a recipient, the sheet's users are the server's invitable_to too: never a user whom the admin \
    sees only through the admin's access
    """
  )
  func sheetForTheAdmin() async throws {
    let instance = try await Instance(server: try await TestServer.start())
    let builder = instance.builder
    let admin = builder.admin
    let grandpa = try await builder.person("Grandpa")
    let ghost = try await builder.person("Ghost")
    let stranger = try await builder.person("Stranger")
    _ = try await builder.group("Home", users: [admin, grandpa, ghost])
    _ = try await builder.deactivate(ghost)
    let list = try await builder.list("Our house", of: admin)
    let session = try await signedIn(as: admin, on: instance)
    // The admin sees the stranger in full, through the admin's access.
    #expect(session.user(id: stranger.id)?.isSummary == false)

    let server = try await invitable(to: list, as: admin)
    #expect(server == [grandpa.id])
    #expect(session.invitableUsers(toList: list.id).map(\.id) == server)

    // An invite of the stranger does nothing.
    await session.invite(stranger.id, toList: list.id)
    #expect(session.unsentChangeCount == 0)
    #expect(session.otherInvitations(toList: list.id).isEmpty)
  }

  // MARK: - 2. A tap invites at once

  @Test(
    """
    A tap invites at once: the invitation shows on the page, invited by the user, with Withdraw, and the user leaves \
    the sheet, which stays for another. The server has the invitation, by the user
    """
  )
  func tapInvites() async throws {
    let family = try await family()
    let session = try await signedIn(as: family.me)
    let id = family.ourHouse.id
    #expect(session.listPage(id: id)?.offersInvite == true)
    #expect(session.listPage(id: id)?.otherInvitations == [])

    await session.invite(family.grandpa.id, toList: id)

    // At once.
    let page = try #require(session.listPage(id: id))
    let shown = try #require(page.otherInvitations.first)
    #expect(page.otherInvitations.count == 1)
    #expect(StandIn.isStandIn(shown.id))
    #expect(shown.user.id == family.grandpa.id)
    #expect(shown.user.name == family.grandpa.name)
    #expect(shown.inviterName == family.me.name)
    #expect(shown.canWithdraw)
    #expect(!session.invitableUsers(toList: id).map(\.id).contains(family.grandpa.id))
    #expect(Set(session.invitableUsers(toList: id).map(\.id)) == [family.dad.id, family.emma.id])
    // A second tap on the same user does nothing.
    await session.invite(family.grandpa.id, toList: id)
    #expect(session.unsentChangeCount <= 1)
    // The invitation is for someone else: nothing at the top of the page, and nothing on the Lists tab.
    #expect(session.pendingInvitations(toList: id).isEmpty)

    // The next user, from the sheet that stayed.
    await session.invite(family.dad.id, toList: id)
    #expect(session.listPage(id: id)?.otherInvitations.map(\.user.id) == [family.grandpa.id, family.dad.id])

    await until { session.unsentChangeCount == 0 }
    let saved = try await invitations(to: family.ourHouse, as: family.me)
    #expect(Set(saved.compactMap { $0["user"]["id"].string }) == [family.grandpa.id, family.dad.id])
    #expect(saved.allSatisfy { $0["invited_by"]["id"].string == family.me.id })
    #expect(requests.filter { $0.isOn(Self.createInvitation) }.count == 2)
    #expect(requests.allSatisfy { !$0.target.contains(StandIn.prefix) })

    // The page shows the server's invitations, by the server's IDs.
    try await untilInStep(session, as: family.me)
    let ids = Set(saved.compactMap { $0["id"].string })
    #expect(Set(session.otherInvitations(toList: id).map(\.id)) == ids)
    #expect(session.otherInvitations(toList: id).allSatisfy { $0.inviterName == family.me.name && $0.canWithdraw })
    #expect(session.lateRefusals.isEmpty)
  }

  @Test(
    """
    An invite of the user's own child shows at the top of the page, as the child's invitation, with Decline, and not \
    among the other invitations. Accept shows once the server has it
    """
  )
  func inviteOwnChild() async throws {
    let family = try await family()
    let session = try await signedIn(as: family.me)
    let id = family.ourHouse.id

    await session.invite(family.emma.id, toList: id)

    let top = try #require(session.pendingInvitations(toList: id).first)
    #expect(top.invited == .child(name: family.emma.name))
    #expect(top.inviterName == family.me.name)
    #expect(top.canDecline)
    #expect(!top.canAccept)
    #expect(session.otherInvitations(toList: id).isEmpty)
    #expect(!session.invitableUsers(toList: id).map(\.id).contains(family.emma.id))

    await until { session.unsentChangeCount == 0 }
    try await untilInStep(session, as: family.me)
    let saved = try #require(try await invitations(to: family.ourHouse, as: family.me).first)
    let shown = try #require(session.pendingInvitations(toList: id).first)
    #expect(shown.id == saved["id"].string)
    #expect(shown.canAccept)
    #expect(session.otherInvitations(toList: id).isEmpty)
  }

  // MARK: - 3. Offline, a lost answer, and already invited

  @Test("An invite made with the network dropped shows at once, and is sent when the instance answers")
  func offlineThenOnline() async throws {
    let family = try await family()
    let session = try await signedIn(as: family.me)
    instance.conditioner.dropEverything()

    await session.invite(family.grandpa.id, toList: family.ourHouse.id)
    await until { session.isInstanceUnreachable }
    #expect(session.unsentChangeCount == 1)
    #expect(session.otherInvitations(toList: family.ourHouse.id).map(\.user.id) == [family.grandpa.id])
    #expect(try await invitations(to: family.ourHouse, as: family.me).isEmpty)

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    let saved = try await invitations(to: family.ourHouse, as: family.me)
    #expect(saved.compactMap { $0["user"]["id"].string } == [family.grandpa.id])
    await until {
      session.otherInvitations(toList: family.ourHouse.id).map(\.id) == saved.compactMap { $0["id"].string }
    }
    #expect(session.lateRefusals.isEmpty)
  }

  @Test("The server's answer is lost. The resend has the same key, and the server has one invitation")
  func lostAnswerSendsOnce() async throws {
    let family = try await family()
    let session = try await signedIn(as: family.me)
    instance.conditioner.dropEverything()
    await session.invite(family.grandpa.id, toList: family.ourHouse.id)
    await until { session.isInstanceUnreachable }

    // The network is back. The server makes the invitation, and its answer is lost on the way back.
    instance.conditioner.passEverything()
    let hold = instance.conditioner.hold(Self.createInvitation, at: .answer)
    let sync = Task { await session.syncNow() }
    await hold.waitUntilHeld()
    instance.conditioner.dropEverything()
    _ = await sync.value
    #expect(session.unsentChangeCount == 1)
    #expect(try await invitations(to: family.ourHouse, as: family.me).count == 1)
    #expect(session.otherInvitations(toList: family.ourHouse.id).count == 1)

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    let creates = requests.filter { $0.isOn(Self.createInvitation) }
    #expect(creates.count >= 2)
    #expect(Set(creates.compactMap { $0.headers["idempotency-key"] }).count == 1)
    #expect(creates.allSatisfy { $0.headers["idempotency-key"] != nil })
    let saved = try await invitations(to: family.ourHouse, as: family.me)
    #expect(saved.count == 1)
    await until {
      session.otherInvitations(toList: family.ourHouse.id).map(\.id) == saved.compactMap { $0["id"].string }
    }
    #expect(session.lateRefusals.isEmpty)
  }

  @Test(
    """
    An invite of a user whom another recipient invited meanwhile is a success: already_invited. A withdraw of the \
    user's own invite goes with it, and the other recipient's invitation stays
    """
  )
  func alreadyInvited() async throws {
    let builder = instance.builder
    let family = try await family()
    let aunt = try await builder.person("Aunt")
    _ = try await builder.group("Cousins", users: [family.me, family.dad, aunt])
    try await builder.accept(try await builder.invite(family.dad, to: family.ourHouse, as: family.me))
    let diagnostics = RecordingDiagnostics()
    let session = try await signedIn(as: family.me, diagnostics: diagnostics)
    instance.conditioner.dropEverything()

    await session.invite(family.grandpa.id, toList: family.ourHouse.id)
    await session.invite(aunt.id, toList: family.ourHouse.id)
    let invited = try #require(session.otherInvitations(toList: family.ourHouse.id).first { $0.user.id == aunt.id })
    await session.withdrawInvitation(invited.id)
    #expect(session.otherInvitations(toList: family.ourHouse.id).map(\.user.id) == [family.grandpa.id])
    await until { session.isInstanceUnreachable }
    // Meanwhile, Dad invites both.
    let byDad = try await builder.invite(family.grandpa, to: family.ourHouse, as: family.dad)
    let auntByDad = try await builder.invite(aunt, to: family.ourHouse, as: family.dad)

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    try await untilInStep(session, as: family.me)
    #expect(session.lateRefusals.isEmpty)
    #expect(diagnostics.faults.isEmpty)
    // Both invites were sent, and the withdraw was not: Dad's invitations stay, and show as his.
    #expect(requests.filter { $0.isOn(Self.createInvitation) }.count == 2)
    #expect(!requests.contains { $0.isOn(Self.withdraw) })
    let saved = try await invitations(to: family.ourHouse, as: family.me)
    #expect(Set(saved.compactMap { $0["id"].string }) == [byDad.id, auntByDad.id])
    let shown = session.otherInvitations(toList: family.ourHouse.id)
    #expect(Set(shown.map(\.id)) == [byDad.id, auntByDad.id])
    #expect(shown.allSatisfy { $0.inviterName == family.dad.name })
  }

  @Test(
    """
    An invite of a user who accepted another recipient's invitation meanwhile is a success: already_recipient. The \
    user is on the list
    """
  )
  func alreadyRecipient() async throws {
    let builder = instance.builder
    let family = try await family()
    try await builder.accept(try await builder.invite(family.dad, to: family.ourHouse, as: family.me))
    let diagnostics = RecordingDiagnostics()
    let session = try await signedIn(as: family.me, diagnostics: diagnostics)
    instance.conditioner.dropEverything()

    await session.invite(family.grandpa.id, toList: family.ourHouse.id)
    await until { session.isInstanceUnreachable }
    // Meanwhile, Dad invites Grandpa, and Grandpa accepts.
    try await builder.accept(try await builder.invite(family.grandpa, to: family.ourHouse, as: family.dad))

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    try await untilInStep(session, as: family.me)
    #expect(session.lateRefusals.isEmpty)
    #expect(diagnostics.faults.isEmpty)
    #expect(requests.filter { $0.isOn(Self.createInvitation) }.count == 1)
    #expect(try await invitations(to: family.ourHouse, as: family.me).isEmpty)
    #expect(session.otherInvitations(toList: family.ourHouse.id).isEmpty)
    #expect(session.list(id: family.ourHouse.id)?.recipientIDs.contains(family.grandpa.id) == true)
  }

  // MARK: - 4. Withdraw

  @Test(
    """
    Withdraw shows from can_delete, and takes the invitation out at once. The user can be invited again, and the \
    server no longer has it
    """
  )
  func withdraw() async throws {
    let builder = instance.builder
    let family = try await family()
    let invitation = try await builder.invite(family.grandpa, to: family.ourHouse, as: family.me)
    let session = try await signedIn(as: family.me)
    let shown = try #require(session.otherInvitations(toList: family.ourHouse.id).first)
    #expect(shown.id == invitation.id)
    #expect(shown.row.canDelete)
    #expect(shown.canWithdraw)
    #expect(!session.invitableUsers(toList: family.ourHouse.id).map(\.id).contains(family.grandpa.id))

    await session.withdrawInvitation(invitation.id)

    #expect(session.otherInvitations(toList: family.ourHouse.id).isEmpty)
    #expect(session.invitableUsers(toList: family.ourHouse.id).map(\.id).contains(family.grandpa.id))
    await until { session.unsentChangeCount == 0 }
    #expect(try await family.me.signedIn().status(of: "/invitations/\(invitation.id)") == 404)
    try await untilInStep(session, as: family.me)
    #expect(session.otherInvitations(toList: family.ourHouse.id).isEmpty)
    #expect(session.lateRefusals.isEmpty)
  }

  @Test("Withdraw doesn't show for an invitation whose can_delete is false, and does nothing for it")
  func withdrawFromCanDelete() async throws {
    let builder = instance.builder
    let family = try await family()
    let invitation = try await builder.invite(family.grandpa, to: family.ourHouse, as: family.me)
    let session = try await signedIn(as: family.me)
    // The server gives a recipient can_delete on every invitation to the list, so the copy's row says false here.
    try await session.database.change { database in
      let row = try #require(try InvitationRow.fetchOne(database, key: invitation.id))
      try InvitationRow(
        id: row.id, listID: row.listID, listName: row.listName, userID: row.userID, invitedByID: row.invitedByID,
        createdAt: row.createdAt, canAccept: row.canAccept, canDelete: false, version: row.version
      ).update(database)
    }
    await until { session.otherInvitations(toList: family.ourHouse.id).first?.canWithdraw == false }

    await session.withdrawInvitation(invitation.id)
    #expect(session.unsentChangeCount == 0)
    #expect(session.otherInvitations(toList: family.ourHouse.id).map(\.id) == [invitation.id])
  }

  @Test(
    """
    A withdraw of an invitation that the invited user declined meanwhile gets a 404: it is a late refusal, as the \
    spec has it, and is never captured. The invitation is gone
    """
  )
  func withdrawDeclinedElsewhere() async throws {
    let builder = instance.builder
    let family = try await family()
    let invitation = try await builder.invite(family.grandpa, to: family.ourHouse, as: family.me)
    let diagnostics = RecordingDiagnostics()
    let session = try await signedIn(as: family.me, diagnostics: diagnostics)
    instance.conditioner.dropEverything()
    await session.withdrawInvitation(invitation.id)
    await until { session.isInstanceUnreachable }
    _ = try await family.grandpa.signedIn().send("DELETE", "/invitations/\(invitation.id)").expecting(204)

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    await until { session.lateRefusals.count == 1 }
    #expect(diagnostics.faults.isEmpty)
    try await untilInStep(session, as: family.me)
    #expect(session.otherInvitations(toList: family.ourHouse.id).isEmpty)

    await session.cameToForeground(window: window)
    let refusal = try #require(session.lateRefusalAlert?.refusals.first)
    #expect(
      refusal.action
        == .withdrawInvitation(WithdrawnInvitation(invitationID: invitation.id, userName: family.grandpa.name)))
    #expect(refusal.title == family.ourHouse.name)
    #expect(refusal.refusal.status == 404)
  }

  @Test(
    """
    An invite that the server refuses, because the admin deactivated the user meanwhile, goes from the page with a \
    withdraw of it, shows once, and is captured by its route and code. The user no longer sees a deactivated user, \
    so the server's code is reference_not_found
    """
  )
  func refusedLate() async throws {
    let builder = instance.builder
    let family = try await family()
    let diagnostics = RecordingDiagnostics()
    let session = try await signedIn(as: family.me, diagnostics: diagnostics)
    instance.conditioner.dropEverything()
    await session.invite(family.grandpa.id, toList: family.ourHouse.id)
    let shown = try #require(session.otherInvitations(toList: family.ourHouse.id).first)
    await session.withdrawInvitation(shown.id)
    await session.invite(family.grandpa.id, toList: family.ourHouse.id)
    #expect(session.otherInvitations(toList: family.ourHouse.id).count == 1)
    await until { session.isInstanceUnreachable }
    _ = try await builder.deactivate(family.grandpa)

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    await until { session.lateRefusals.count == 2 }
    #expect(
      diagnostics.faults == Array(repeating: .refusedWrite(.createInvitation, code: "reference_not_found"), count: 2))
    #expect(!requests.contains { $0.isOn(Self.withdraw) })
    #expect(session.otherInvitations(toList: family.ourHouse.id).isEmpty)
    #expect(try await invitations(to: family.ourHouse, as: family.me).isEmpty)

    await session.cameToForeground(window: window)
    let refusals = try #require(session.lateRefusalAlert?.refusals)
    #expect(refusals.count == 2)
    for refusal in refusals {
      guard case .createInvitation(let invitation) = refusal.action else {
        Issue.record("The refusal was of \(refusal.action)")
        continue
      }
      #expect(invitation.userID == family.grandpa.id)
      #expect(invitation.userName == family.grandpa.name)
      #expect(refusal.title == family.ourHouse.name)
      #expect(refusal.refusal.code == .referenceNotFound)
    }
  }

  // MARK: - 5. Invite shows only from can_invite

  @Test(
    """
    Invite shows only from can_invite: never on a primary list, a list the user isn't a recipient of, or a child's \
    list that the user only edits. Nobody can be invited there, and an invite does nothing
    """
  )
  func onlyFromCanInvite() async throws {
    let builder = instance.builder
    let family = try await family()
    let primary = try await builder.primaryList(of: family.me)
    let garden = try await builder.list("Garden", of: family.grandpa)
    let emmas = try await builder.list("Emma's room", of: family.emma)
    let session = try await signedIn(as: family.me)

    #expect(session.listPage(id: family.ourHouse.id)?.offersInvite == true)
    for list in [primary, garden, emmas] {
      let page = try #require(session.listPage(id: list.id), "\(list.name)")
      #expect(!page.list.canInvite, "\(list.name)")
      #expect(!page.offersInvite, "\(list.name)")
      #expect(session.invitableUsers(toList: list.id).isEmpty, "\(list.name)")
      #expect(try await invitable(to: list, as: family.me).isEmpty, "\(list.name)")
      await session.invite(family.dad.id, toList: list.id)
    }
    #expect(session.unsentChangeCount == 0)
    // Garden's own recipient can invite, and the user, a giver there, sees nothing of it.
    _ = try await builder.invite(family.dad, to: garden, as: family.grandpa)
    await session.syncNow()
    try await untilInStep(session, as: family.me)
    #expect(session.listPage(id: garden.id)?.otherInvitations == [])
  }

  // MARK: - 6. Nobody to invite

  @Test("With nobody to invite, Invite still shows, and the sheet has nobody")
  func nobodyToInvite() async throws {
    let builder = instance.builder
    let me = try await builder.person("Robin")
    let list = try await builder.list("Our house", of: me)
    let session = try await signedIn(as: me)
    #expect(session.listPage(id: list.id)?.offersInvite == true)
    #expect(session.invitableUsers(toList: list.id).isEmpty)
    #expect(try await invitable(to: list, as: me).isEmpty)
  }

  // MARK: - A list that New list makes

  @Test(
    """
    With the network dropped: a new list, two users invited to it, and one invitation withdrawn. The sync makes one \
    list with one pending invitation, by the user, and every request names the server's IDs
    """
  )
  func newListOffline() async throws {
    let family = try await family()
    let session = try await signedIn(as: family.me)
    let name = "Shed \(instance.builder.tag)"
    instance.conditioner.dropEverything()

    var draft = session.newListDraft()
    draft.name = name
    let id = try #require(await session.createList(draft))
    #expect(session.listPage(id: id)?.offersInvite == true)
    #expect(
      Set(session.invitableUsers(toList: id).map(\.id)) == [family.grandpa.id, family.dad.id, family.emma.id])
    await session.invite(family.grandpa.id, toList: id)
    await session.invite(family.dad.id, toList: id)
    let dad = try #require(session.otherInvitations(toList: id).first { $0.user.id == family.dad.id })
    await session.withdrawInvitation(dad.id)
    #expect(session.otherInvitations(toList: id).map(\.user.id) == [family.grandpa.id])
    #expect(session.otherInvitations(toList: id).allSatisfy { $0.row.listID == id })
    await until { session.isInstanceUnreachable }

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    let lists = try await family.me.signedIn().all("/lists").filter { $0["name"].string == name }
    #expect(lists.count == 1)
    let serverID = try #require(lists.first?["id"].string)
    let saved = try await family.me.signedIn().all("/invitations?list_id=\(serverID)")
    #expect(saved.compactMap { $0["user"]["id"].string } == [family.grandpa.id])
    #expect(saved.first?["invited_by"]["id"].string == family.me.id)
    #expect(requests.allSatisfy { !$0.target.contains(StandIn.prefix) })
    let createAt = try #require(requests.firstIndex { $0.isOn(Self.createList) })
    #expect(requests.indices.filter { requests[$0].isOn(Self.createInvitation) }.allSatisfy { $0 > createAt })

    // The page that the stand-in opened shows the list and its invitation, by the server's IDs.
    try await untilInStep(session, as: family.me)
    #expect(session.listPage(id: id)?.list.id == serverID)
    #expect(session.otherInvitations(toList: id).map(\.id) == saved.compactMap { $0["id"].string })
    #expect(session.lateRefusals.isEmpty)
  }

  @Test(
    """
    A refused new list takes its invitations with it: none is sent, the page and its invitations go, and only the \
    list's refusal shows
    """
  )
  func refusedListTakesItsInvitations() async throws {
    let family = try await family()
    let session = try await signedIn(as: family.me)
    let name = "Shed \(instance.builder.tag)"
    instance.conditioner.dropEverything()
    var draft = session.newListDraft()
    draft.name = name
    let id = try #require(await session.createList(draft))
    await session.invite(family.grandpa.id, toList: id)
    await session.invite(family.dad.id, toList: id)
    let dad = try #require(session.otherInvitations(toList: id).first { $0.user.id == family.dad.id })
    await session.withdrawInvitation(dad.id)
    await until { session.isInstanceUnreachable }

    // The real server makes a list of the user's own, so the refusal is canned.
    instance.conditioner.passEverything()
    instance.conditioner.answer(Self.createList, with: try .problem(403, code: "forbidden"))
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    await until { session.list(id: id) == nil }
    #expect(session.otherInvitations(toList: id).isEmpty)
    #expect(!requests.contains { $0.isOn(Self.createInvitation) || $0.isOn(Self.withdraw) })
    #expect(try await family.me.signedIn().all("/lists").filter { $0["name"].string == name }.isEmpty)
    await until { session.lateRefusals.count == 1 }
    guard case .createList = session.lateRefusals.first?.action else {
      Issue.record("The refusal was of \(String(describing: session.lateRefusals.first?.action))")
      return
    }
  }
}
