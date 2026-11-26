import Dispatch
import Foundation
import Testing

@testable import WishboneAPI
@testable import WishboneSession

/// What an accept shows over the copy, before the server answers, and which invitations show with which answers. See
/// "Unsent changes" and "A deactivated child" in `docs/spec.md`, and `Journal.swift`. `InvitationsTests` holds the
/// rest against the real server.
@Suite("An accept over the copy", .timeLimit(.minutes(1)))
struct AcceptedListTests {
  private let invitation = AcceptedInvitation(
    invitationID: "5", listID: "9", listName: "Cousins", userID: "me", invitedByID: "mom",
    createdAt: Date(timeIntervalSince1970: 0))

  private func change(_ action: UnsentChange.Action) -> UnsentChange {
    UnsentChange(id: 1, action: action, title: "Cousins", key: "key")
  }

  private func list(_ id: String, _ name: String, recipients: [String]) -> ListRow {
    ListRow(
      id: id, name: name, description: nil, isPrimary: false, recipientIDs: recipients, itemCount: 3,
      createdAt: Date(timeIntervalSince1970: 0), canEdit: false, canDelete: false, canInvite: false, canLeave: false,
      version: "\"1\"")
  }

  @Test("An accept adds the invited user to the list's recipients, once")
  func addsTheRecipient() {
    let rows = [list("9", "Cousins", recipients: ["mom"])]
    let shown = LocalDatabase.applying([change(.acceptInvitation(invitation))], to: rows)
    #expect(shown.map(\.recipientIDs) == [["mom", "me"]])
    #expect(shown.first?.itemCount == 3)
    let twice = LocalDatabase.applying([change(.acceptInvitation(invitation))], to: shown)
    #expect(twice.map(\.recipientIDs) == [["mom", "me"]])
  }

  @Test("A list that the copy doesn't hold shows by its name, with the inviter and the user, among the lists by name")
  func standsInForAListNotInTheCopy() throws {
    let rows = [list("1", "Attic", recipients: ["me"]), list("2", "Zoo", recipients: ["me"])]
    let shown = LocalDatabase.applying([change(.acceptInvitation(invitation))], to: rows)
    #expect(shown.map(\.id) == ["1", "9", "2"])
    let standIn = try #require(shown.first { $0.id == "9" })
    #expect(standIn.name == "Cousins")
    #expect(standIn.recipientIDs == ["mom", "me"])
    #expect(standIn.itemCount == 0)
    #expect(!standIn.canEdit && !standIn.canDelete && !standIn.canInvite && !standIn.canLeave)
  }

  @Test("An accepted or declined invitation is left out of the invitations")
  func answeredInvitationsLeave() {
    let rows = ["5", "6", "7"].map {
      InvitationRow(
        id: $0, listID: "9", listName: "Cousins", userID: "me", invitedByID: "mom",
        createdAt: Date(timeIntervalSince1970: 0), canAccept: true, canDelete: true, version: "\"1\"")
    }
    let shown = LocalDatabase.applying(
      [change(.acceptInvitation(invitation)), change(.declineInvitation(invitationID: "7"))], to: rows)
    #expect(shown.map(\.id) == ["6"])
  }

  // MARK: - Which invitations show, with which answers

  private func invitationRow(
    _ id: String, to userID: String, canAccept: Bool = true, canDelete: Bool = true
  ) -> InvitationRow {
    InvitationRow(
      id: id, listID: "9", listName: "Cousins", userID: userID, invitedByID: "mom",
      createdAt: Date(timeIntervalSince1970: 0), canAccept: canAccept, canDelete: canDelete, version: "\"1\"")
  }

  /// A user as a parent sees their child: in full, deactivated or not.
  private func child(_ id: String, _ name: String, isDeactivated: Bool) -> UserRow {
    UserRow(
      id: id, name: name, avatar: nil,
      record: UserRow.Record(
        lastName: nil, birthday: PartialDate(month: 3, day: 4), goodToKnow: nil, isAdmin: false, parentIDs: ["me"],
        childIDs: [], primaryListID: nil, timezone: .shown("Europe/Paris"), profileConfirmedAt: .shown(nil),
        deactivatedAt: .shown(isDeactivated ? Date(timeIntervalSince1970: 0) : nil),
        createdAt: Date(timeIntervalSince1970: 0), canEdit: true, canEditParents: false, canMakeLoginLink: true,
        canManageSessions: true, canDeactivate: false, canReactivate: false, canConfirmProfile: true,
        canAddOccasion: true),
      version: "\"1\"")
  }

  private func pending(_ rows: [InvitationRow]) -> [PendingInvitation] {
    let users = [child("emma", "Emma", isDeactivated: false), child("sam", "Sam", isDeactivated: true)]
    return PendingInvitation.pending(
      rows, userID: "me", childIDs: ["emma", "sam"], user: { id in users.first { $0.id == id } },
      hasList: { _ in true })
  }

  @Test("A deactivated child's invitation shows with no Accept, even when the server allows it")
  func deactivatedChildHasNoAccept() throws {
    let shown = pending([invitationRow("1", to: "emma"), invitationRow("2", to: "sam"), invitationRow("3", to: "me")])
    #expect(shown.map(\.id) == ["1", "2", "3"])
    #expect(shown.map(\.canAccept) == [true, false, true])
    #expect(shown.map(\.canDecline) == [true, true, true])
    #expect(shown.map(\.invited) == [.child(name: "Emma"), .child(name: "Sam"), .you])
  }

  @Test("Decline shows only from the invitation's can_delete")
  func declineFromCanDelete() {
    let shown = pending([
      invitationRow("1", to: "me", canDelete: false), invitationRow("2", to: "emma", canDelete: false),
      invitationRow("3", to: "me", canAccept: false),
    ])
    #expect(shown.map(\.canDecline) == [false, false, true])
    #expect(shown.map(\.canAccept) == [true, true, false])
  }

  // MARK: - The answer, in the copy

  private func invitation(_ id: String) throws -> Versioned<Invitation> {
    let body = #"""
      {"id":"\#(id)","list":{"id":"9","name":"Cousins"},"user":{"id":"me","name":"Me","avatar":null},
      "invited_by":{"id":"mom","name":"Mom","avatar":null},"created_at":"2026-11-25T10:00:00Z",
      "can_accept":true,"can_delete":true}
      """#
    return Versioned(resource: try JSONDecoder().decode(Invitation.self, from: Data(body.utf8)), version: "\"1\"")
  }

  private func accepted(_ id: String) -> AcceptedInvitation {
    AcceptedInvitation(
      invitationID: id, listID: "9", listName: "Cousins", userID: "me", invitedByID: "mom",
      createdAt: Date(timeIntervalSince1970: 0))
  }

  @Test("The server's yes to an accept or a decline takes the invitation out of the copy, with no pull after it")
  func answerRemovesTheInvitation() async throws {
    let database = try LocalDatabase.inMemory()
    try await database.save([try invitation("5"), try invitation("7"), try invitation("8")])

    try await database.record(.acceptInvitation(accepted("5")), title: "Cousins")
    try await database.accept(try #require(try await database.firstUnsentChange()), answer: .none)
    #expect(try await database.snapshot(ofUser: "me").invitations.map(\.id) == ["7", "8"])

    try await database.record(.declineInvitation(invitationID: "7"), title: "Cousins")
    try await database.accept(try #require(try await database.firstUnsentChange()), answer: .none)
    let snapshot = try await database.snapshot(ofUser: "me")
    #expect(snapshot.invitations.map(\.id) == ["8"])
    #expect(snapshot.unsentChangeCount == 0)
  }

  @Test("An answered invitation stays out while its change waits, and comes back after a refusal, with no pull")
  @MainActor
  func answeredInvitationWaitsAndComesBack() async throws {
    let database = try LocalDatabase.inMemory()
    try await database.save([try invitation("5"), try invitation("7")])
    var shown: [String] = []
    let observation = database.observeSnapshots(ofUser: "me") { shown = $0.invitations.map(\.id) }
    defer { observation.cancel() }
    // The observation gives each snapshot on the main queue, in order. A block put on it now runs after them.
    func given() async -> [String] {
      await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
      return shown
    }
    #expect(await given() == ["5", "7"])

    try await database.record(.acceptInvitation(accepted("5")), title: "Cousins")
    try await database.record(.declineInvitation(invitationID: "7"), title: "Cousins")
    #expect(await given() == [])

    let accept = try #require(try await database.firstUnsentChange())
    try await database.refuse(
      accept, refusal: APIError.Refusal(route: .acceptInvitation, status: 404, code: .notFound, detail: ""))
    #expect(await given() == ["5"])

    let decline = try #require(try await database.firstUnsentChange())
    try await database.refuse(
      decline, refusal: APIError.Refusal(route: .declineInvitation, status: 404, code: .notFound, detail: ""))
    #expect(await given() == ["5", "7"])
  }
}
