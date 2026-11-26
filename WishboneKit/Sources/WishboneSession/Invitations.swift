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
