import Foundation
import WishboneAPI

// The invitations that wait for the session's user: the ones to them, and the ones to their children. They show at
// the top of the Lists tab, and at the top of the list's page, with Accept and Decline. See `docs/screens/lists.md`
// and `docs/screens/list.md`, and in `docs/spec.md`: "Unsent changes", "A deactivated child", and "The rest, as the
// server has it".
//
// **Each answer is an unsent change,** with no confirmation. It shows at once, in every window: the invitation goes,
// and after an accept the list moves into the user's own lists, or into the child's part. A sync sends it, now or
// when the instance answers. A refusal rolls it back, and shows once (see `UnsentChanges.swift`).
//
// **No claim state.** After an accept, the list's page shows the list as its recipients see it: the user, or their
// child, is a recipient at once, and a recipient's rows have none. The next sync brings the list as the server shows
// it to a recipient.

/// A pending invitation for the session's user or one of their children, as the Lists tab and the list's page show
/// it.
public struct PendingInvitation: Equatable, Sendable, Identifiable {
  public let row: InvitationRow

  /// Who is invited: the session's user, or one of their children.
  public let invited: Invited

  /// The name of the recipient who invited them. Nil once that user is deleted.
  public let inviterName: String?

  /// Whether Accept shows: the invitation's `can_accept`, and never for a deactivated child.
  public let canAccept: Bool

  /// Whether Decline shows: the invitation's `can_delete`.
  public let canDecline: Bool

  /// Whether a tap on the invitation's text opens the list's page: the copy holds the list, so the user can see it.
  public let opensList: Bool

  /// Who an invitation is for.
  public enum Invited: Equatable, Sendable {
    /// The session's user: "Mom invited you to Our house".
    case you

    /// One of the user's children, by name: "Mom invited Emma to Cousins".
    case child(name: String)
  }

  public var id: String { row.id }

  /// The invitations, in their order, as the user sees them: the ones to the user, and the ones to the children
  /// with `childIDs`. `user` gives a user's row from the copy, and `hasList` whether the copy holds a list.
  static func pending(
    _ invitations: [InvitationRow], userID me: String, childIDs children: Set<String>,
    user: (String) -> UserRow?, hasList: (String) -> Bool
  ) -> [PendingInvitation] {
    invitations.compactMap { row in
      let invited: Invited
      var isDeactivated = false
      if row.userID == me {
        invited = .you
      } else if children.contains(row.userID), let child = user(row.userID) {
        invited = .child(name: child.name)
        isDeactivated = child.isDeactivated
      } else {
        return nil
      }
      return PendingInvitation(
        row: row,
        invited: invited,
        inviterName: row.invitedByID.flatMap { user($0)?.name },
        canAccept: row.canAccept && !isDeactivated,
        canDecline: row.canDelete,
        opensList: hasList(row.listID))
    }
  }
}

extension SessionModel {
  /// The pending invitations for the session's user and for their children, the oldest first. An invitation that an
  /// unsent change answers is not among them. The invitations to the lists that the user is a recipient of, for
  /// someone else, are not either.
  public var pendingInvitations: [PendingInvitation] {
    PendingInvitation.pending(
      invitations, userID: session.userID, childIDs: Set(user?.record?.childIDs ?? []), user: { user(id: $0) },
      hasList: { list(id: $0) != nil })
  }

  /// The pending invitations to the list for the session's user and for their children, for the top of its page.
  public func pendingInvitations(toList id: String) -> [PendingInvitation] {
    pendingInvitations.filter { $0.row.listID == id }
  }

  /// Accept: the session's user, or their child, becomes a recipient of the list, as an unsent change. The
  /// invitation goes at once, and the list moves into the user's own lists, or into the child's part.
  ///
  /// It does nothing for an invitation that is not pending for the user or one of their children, or that they
  /// can't accept. It returns when the change is in the journal and published, and doesn't wait for the sync.
  public func acceptInvitation(_ id: String) async {
    guard !hasEnded, let invitation = pendingInvitations.first(where: { $0.id == id }), invitation.canAccept
    else { return }
    await record(.acceptInvitation(AcceptedInvitation(invitation.row)), title: invitation.row.listName)
  }

  /// Decline: removes the invitation, as an unsent change. It goes at once.
  ///
  /// It does nothing for an invitation that is not pending for the user or one of their children, or that they
  /// can't decline. It returns when the change is in the journal and published, and doesn't wait for the sync.
  public func declineInvitation(_ id: String) async {
    guard !hasEnded, let invitation = pendingInvitations.first(where: { $0.id == id }), invitation.canDecline
    else { return }
    await record(.declineInvitation(invitationID: id), title: invitation.row.listName)
  }
}

// Invite and Withdraw, on a list's page, for a recipient of an extra list. See Invite and Withdraw in
// `docs/screens/list.md`, "Unsent changes" in `docs/spec.md`, and the server's route table for `?invitable_to=`.
//
// **Who can be invited** comes from the copy, by the server's rule: users whom the user can see, with the admin's
// access not counted (their children, their parents, and the users of their groups: Home's People), who are active,
// are not recipients of the list, and have no pending invitation to it. So the admin, as a recipient, can invite only
// the people they see as anyone else does.
//
// **Each is an unsent change,** with no confirmation. An invite shows on the page at once, by a stand-in ID, and the
// user leaves the Invite sheet. A withdraw takes the invitation out at once. A refusal rolls it back, and shows once
// (see `UnsentChanges.swift`).

/// A pending invitation to a list, for someone other than the session's user and their children, as a recipient of
/// the list sees it on the list's page: "Grandpa · invited by Mom", with Withdraw.
public struct ListInvitation: Equatable, Sendable, Identifiable {
  public let row: InvitationRow

  /// The invited user, in full or as a summary: their name and avatar.
  public let user: UserRow

  /// The name of the recipient who invited them. Nil once that user is deleted.
  public let inviterName: String?

  /// Whether Withdraw shows: the invitation's `can_delete`.
  public let canWithdraw: Bool

  public var id: String { row.id }
}

extension SessionModel {
  /// The list's other pending invitations, for its page: the ones that a recipient of the list sees, for anyone but
  /// the user and their children, whose invitations are at the top of the page. The oldest first, and an invite that
  /// waits to be sent last. Empty for a user who is not a recipient of the list.
  public func otherInvitations(toList id: String) -> [ListInvitation] {
    guard let list = list(id: id), list.recipientIDs.contains(session.userID) else { return [] }
    let shown = Set(pendingInvitations(toList: list.id).map(\.id))
    return invitations.compactMap { row in
      guard row.listID == list.id, !shown.contains(row.id), row.userID != session.userID,
        let user = user(id: row.userID)
      else { return nil }
      return ListInvitation(
        row: row, user: user, inviterName: row.invitedByID.flatMap { self.user(id: $0)?.name },
        canWithdraw: row.canDelete)
    }
  }

  /// The users whom the user can invite to the list, by name, for the Invite sheet: whom the user can see, with the
  /// admin's access not counted, who are active, are not recipients of the list, and have no pending invitation to
  /// it. Empty when the list's `can_invite` is false, and for a primary list.
  public func invitableUsers(toList id: String) -> [UserRow] {
    guard let list = list(id: id), list.canInvite, !list.isPrimary else { return [] }
    let seen = Set(people.flatMap { $0.users.map(\.id) })
    let invited = Set(invitations.filter { $0.listID == list.id }.map(\.userID))
    let recipients = Set(list.recipientIDs)
    return users.filter { user in
      seen.contains(user.id) && !user.isSummary && !user.isDeactivated && !recipients.contains(user.id)
        && !invited.contains(user.id)
    }
  }

  /// Invite: invites the user to the list, as an unsent change. The invitation shows on the list's page at once, and
  /// the user leaves the Invite sheet.
  ///
  /// It does nothing for a user whom the session's user can't invite to the list. It returns when the change is in
  /// the journal and published, and doesn't wait for the sync.
  public func invite(_ userID: String, toList id: String) async {
    guard !hasEnded, let list = list(id: id),
      let user = invitableUsers(toList: list.id).first(where: { $0.id == userID })
    else { return }
    let invitation = CreatedInvitation(
      id: StandIn.make(), listID: list.id, listName: list.name, userID: user.id, userName: user.name,
      invitedByID: session.userID, createdAt: .now)
    await record(.createInvitation(invitation), title: list.name)
  }

  /// Withdraw: removes the invitation, as an unsent change, with no confirmation. It goes at once.
  ///
  /// It does nothing for an invitation that is not among its list's other invitations, or that the user can't
  /// withdraw. It returns when the change is in the journal and published, and doesn't wait for the sync.
  public func withdrawInvitation(_ id: String) async {
    guard !hasEnded, let row = invitations.first(where: { $0.id == id }),
      let invitation = otherInvitations(toList: row.listID).first(where: { $0.id == id }), invitation.canWithdraw
    else { return }
    await record(
      .withdrawInvitation(WithdrawnInvitation(invitationID: id, userName: invitation.user.name)),
      title: row.listName)
  }
}
