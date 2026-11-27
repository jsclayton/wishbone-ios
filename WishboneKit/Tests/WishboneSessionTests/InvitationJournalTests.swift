import Foundation
import Testing

@testable import WishboneAPI
@testable import WishboneSession

/// What Invite and Withdraw show over the copy before the server answers, how the journal keeps them, and what an
/// answer or a refusal takes with them. See "Unsent changes" in `docs/spec.md`, and `Journal.swift`. `InviteTests`
/// holds the rest against the real server.
@Suite("An invitation over the copy", .timeLimit(.minutes(1)))
struct InvitationJournalTests {
  private func change(_ action: UnsentChange.Action, id: Int64 = 1) -> UnsentChange {
    UnsentChange(id: id, action: action, title: "Our house", key: "key")
  }

  private func created(_ id: String, of userID: String = "grandpa", toList listID: String = "a") -> CreatedInvitation {
    CreatedInvitation(
      id: id, listID: listID, listName: "Our house", userID: userID, userName: "Grandpa", invitedByID: "me",
      createdAt: Date(timeIntervalSince1970: 0))
  }

  private func withdrawn(_ id: String) -> UnsentChange.Action {
    .withdrawInvitation(WithdrawnInvitation(invitationID: id, userName: "Grandpa"))
  }

  private func row(_ id: String, of userID: String, toList listID: String = "a") -> InvitationRow {
    InvitationRow(
      id: id, listID: listID, listName: "Our house", userID: userID, invitedByID: "mom",
      createdAt: Date(timeIntervalSince1970: 0), canAccept: false, canDelete: true, version: "\"1\"")
  }

  @Test(
    """
    An invite shows at once by its stand-in ID, after the invitations of the copy, invited by the user, with Withdraw \
    and no Accept. A withdraw takes an invitation out, a stand-in's too, in the journal's order
    """
  )
  func shownOverTheCopy() {
    let first = StandIn.make()
    let second = StandIn.make()
    let rows = LocalDatabase.applying(
      [
        change(.createInvitation(created(first))),
        change(.createInvitation(created(second, of: "dad")), id: 2),
        change(withdrawn("5"), id: 3),
        change(withdrawn(second), id: 4),
      ],
      to: [row("5", of: "aunt"), row("6", of: "uncle")])
    #expect(rows.map(\.id) == ["6", first])
    let shown = rows[1]
    #expect(shown.listID == "a")
    #expect(shown.listName == "Our house")
    #expect(shown.userID == "grandpa")
    #expect(shown.invitedByID == "me")
    #expect(shown.canDelete)
    #expect(!shown.canAccept)
    #expect(shown.version == "")

    // An accept and a decline still take theirs out.
    let answered = LocalDatabase.applying(
      [
        change(.acceptInvitation(AcceptedInvitation(row("5", of: "me")))),
        change(.declineInvitation(invitationID: "6")),
      ],
      to: [row("5", of: "me"), row("6", of: "emma"), row("7", of: "aunt")])
    #expect(answered.map(\.id) == ["7"])
  }

  @Test("A new list of the user's own offers Invite at once, and a list for a child doesn't")
  func newListOffersInvite() {
    func list(for recipientID: String) -> CreatedList {
      CreatedList(
        id: StandIn.make(), name: "Our house", description: nil, recipientID: recipientID,
        isForAChild: recipientID != "me", recipientName: "Robin", createdAt: Date(timeIntervalSince1970: 0))
    }
    let lists = LocalDatabase.applying(
      [change(.createList(list(for: "me"))), change(.createList(list(for: "emma")), id: 2)], to: [ListRow]())
    #expect(lists.map(\.recipientIDs) == [["me"], ["emma"]])
    #expect(lists.map(\.canInvite) == [true, false])
  }

  @Test("The journal keeps an invite and a withdraw as they were made, and the invite sends only user_id")
  func keptAndSent() async throws {
    let database = try LocalDatabase.inMemory()
    let invite = created(StandIn.make())
    try await database.record([
      .init(.createInvitation(invite), title: "Our house"), .init(withdrawn(invite.id), title: "Our house"),
      .init(withdrawn("12"), title: "Our house"),
    ])
    let changes = try await database.unsentChangesAndStandIns().changes
    #expect(changes.map(\.action) == [.createInvitation(invite), withdrawn(invite.id), withdrawn("12")])
    #expect(changes.map(\.action.targetID) == [invite.id, invite.id, "12"])

    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    #expect(
      String(decoding: try encoder.encode(NewInvitation(userID: "42")), as: UTF8.self) == #"{"user_id":"42"}"#)
  }

  @Test(
    """
    A refused invite takes a withdraw of it with it, and only the invite's refusal shows. A withdraw of another \
    invitation stays
    """
  )
  func refusalTakesTheWithdraw() async throws {
    let database = try LocalDatabase.inMemory()
    let refused = created(StandIn.make())
    let other = created(StandIn.make(), of: "dad")
    try await database.record([
      .init(.createInvitation(refused), title: "Our house"), .init(.createInvitation(other), title: "Our house"),
      .init(withdrawn(refused.id), title: "Our house"), .init(withdrawn(other.id), title: "Our house"),
      .init(withdrawn("12"), title: "Our house"),
    ])
    let invite = try #require(try await database.firstUnsentChange())
    try await database.refuse(
      invite, refusal: APIError.Refusal(route: .createInvitation, status: 403, code: .userDeactivated, detail: ""))

    let left = try await database.unsentChangesAndStandIns().changes.map(\.action)
    #expect(left == [.createInvitation(other), withdrawn(other.id), withdrawn("12")])
    #expect(try await database.lateRefusals().map(\.action) == [.createInvitation(refused)])
  }

  @Test(
    """
    An invite that the server answers with no invitation, for already_invited or already_recipient, leaves with a \
    withdraw of it: there is no invitation of the user's to withdraw. Nothing shows as refused
    """
  )
  func noInvitationTakesTheWithdraw() async throws {
    let database = try LocalDatabase.inMemory()
    let invite = created(StandIn.make())
    try await database.record([
      .init(.createInvitation(invite), title: "Our house"), .init(withdrawn(invite.id), title: "Our house"),
      .init(withdrawn("12"), title: "Our house"),
    ])
    let first = try #require(try await database.firstUnsentChange())
    try await database.accept(first, answer: .none)
    #expect(try await database.unsentChangesAndStandIns().changes.map(\.action) == [withdrawn("12")])
    #expect(try await database.lateRefusals().isEmpty)
  }

  @Test(
    """
    A refused new list takes the invitations to it, and the withdraws of those. An invitation to another list, and a \
    withdraw of one that the server has, stay
    """
  )
  func refusedListTakesItsInvitations() async throws {
    let database = try LocalDatabase.inMemory()
    let list = CreatedList(
      id: StandIn.make(), name: "Our house", description: nil, recipientID: "me", isForAChild: false,
      recipientName: "Robin", createdAt: Date(timeIntervalSince1970: 0))
    let toIt = created(StandIn.make(), toList: list.id)
    let alsoToIt = created(StandIn.make(), of: "dad", toList: list.id)
    let elsewhere = created(StandIn.make(), toList: "b")
    try await database.record([
      .init(.createList(list), title: "Our house"), .init(.createInvitation(toIt), title: "Our house"),
      .init(.createInvitation(alsoToIt), title: "Our house"), .init(withdrawn(alsoToIt.id), title: "Our house"),
      .init(.createInvitation(elsewhere), title: "Shed"), .init(withdrawn("12"), title: "Shed"),
    ])
    let create = try #require(try await database.firstUnsentChange())
    try await database.refuse(
      create, refusal: APIError.Refusal(route: .createList, status: 403, code: .forbidden, detail: ""))

    let left = try await database.unsentChangesAndStandIns().changes.map(\.action)
    #expect(left == [.createInvitation(elsewhere), withdrawn("12")])
    #expect(try await database.lateRefusals().map(\.action) == [.createList(list)])
  }

  @Test("An invite or a withdraw that can't be read stays in the journal, unsent, and shows nothing")
  func unreadable() async throws {
    for action in [UnsentChange.Action.createInvitation(created(StandIn.make())), withdrawn("12")] {
      let database = try LocalDatabase.inMemory()
      try await database.record(action, title: "Our house")
      try await database.change { database in
        try database.execute(sql: "UPDATE unsentChange SET patch = '{\"userName\": 3}'")
      }
      #expect(try await database.firstUnsentChange() == nil)
      #expect(try await database.unsentChangeCount() == 1)
    }
  }
}
