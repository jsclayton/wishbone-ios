import Foundation
import Testing

@testable import WishboneSession

/// What an accept shows over the copy, before the server answers. See "Unsent changes" in `docs/spec.md`, and
/// `Journal.swift`. `InvitationsTests` holds the rest against the real server.
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
}
