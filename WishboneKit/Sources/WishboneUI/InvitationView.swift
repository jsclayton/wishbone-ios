import SwiftUI
import WishboneSession

/// A pending invitation, at the top of the Lists tab or of the list's page: its line, then Accept and Decline, from
/// its `can_*` fields. Each is an unsent change, with no confirmation: the invitation goes at once, in every window.
/// See `docs/screens/lists.md` and `docs/screens/list.md`.
///
/// On the Lists tab, a tap on the line opens the list's page, when the user can see the list.
///
/// It is one element: the line, with the actions Accept and Decline. The buttons are on screen too.
///
/// **Provisional.** Plain default: a row with the line, and the two buttons under it, Accept the prominent one.
struct InvitationView: View {
  let invitation: PendingInvitation
  let session: SessionModel

  /// Where the row is: the list's page names the list as "this list".
  let isOnListPage: Bool

  /// Opens the list's page. Nil on the list's page itself, or when the user can't see the list.
  let open: (() -> Void)?

  var body: some View {
    let words = InvitationWords.line(
      invited: invitation.invited, inviter: invitation.inviterName, list: invitation.row.listName,
      onListPage: isOnListPage)
    VStack(alignment: .leading, spacing: 10) {
      if let open {
        Button(action: open) {
          Text(words)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
      } else {
        Text(words)
      }
      if invitation.canAccept || invitation.canDecline {
        HStack(spacing: 12) {
          if invitation.canAccept {
            Button(action: accept) {
              Text("Accept", bundle: #bundle)
            }
            .buttonStyle(.borderedProminent)
          }
          if invitation.canDecline {
            Button(action: decline) {
              Text("Decline", bundle: #bundle)
            }
            .buttonStyle(.bordered)
          }
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .padding(.vertical, 4)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(words))
    .accessibilityAddTraits(open == nil ? [] : .isLink)
    .modifier(OpenAction(open: open))
    .accessibilityActions {
      if invitation.canAccept {
        Button(action: accept) {
          Text("Accept", bundle: #bundle)
        }
      }
      if invitation.canDecline {
        Button(action: decline) {
          Text("Decline", bundle: #bundle)
        }
      }
    }
  }

  private func accept() {
    Task { await session.acceptInvitation(invitation.id) }
  }

  private func decline() {
    Task { await session.declineInvitation(invitation.id) }
  }
}

/// The invitation's default action: it opens the list's page. On the list's page, or when the user can't see the
/// list, the invitation has no default action, so VoiceOver offers no double tap that does nothing.
private struct OpenAction: ViewModifier {
  let open: (() -> Void)?

  func body(content: Content) -> some View {
    if let open {
      content.accessibilityAction(.default, open)
    } else {
      content
    }
  }
}

/// The words of an invitation's line. See Words in `docs/screens/lists.md` and `docs/screens/list.md`.
public enum InvitationWords {
  /// The line of one of a list's other invitations, on its page: the invited user's name, then who invited them,
  /// "Grandpa · invited by Mom". With no inviter, who was deleted since, only the name.
  public static func other(invited: String, inviter: String?) -> String {
    guard let inviter else { return invited }
    return String(
      localized: "\(invited) · invited by \(inviter)", bundle: #bundle,
      comment: "One of a list's pending invitations: the invited user's name, then the name of who invited them")
  }

  /// The line: who invited whom, to which list. On the list's page, the list is "this list". With no inviter, who
  /// was deleted since, the line says only who is invited.
  public static func line(
    invited: PendingInvitation.Invited, inviter: String?, list: String, onListPage: Bool
  ) -> String {
    switch (invited, inviter, onListPage) {
    case (.you, let inviter?, false):
      return String(
        localized: "\(inviter) invited you to \(list)", bundle: #bundle,
        comment: "An invitation on the Lists tab: who invited the user, then the list's name")
    case (.you, let inviter?, true):
      return String(
        localized: "\(inviter) invited you to this list", bundle: #bundle,
        comment: "An invitation on the list's page: who invited the user")
    case (.child(let child), let inviter?, false):
      return String(
        localized: "\(inviter) invited \(child) to \(list)", bundle: #bundle,
        comment: "An invitation for the user's child on the Lists tab: who invited them, the child, then the list")
    case (.child(let child), let inviter?, true):
      return String(
        localized: "\(inviter) invited \(child) to this list", bundle: #bundle,
        comment: "An invitation for the user's child on the list's page: who invited them, then the child")
    case (.you, nil, false):
      return String(
        localized: "You're invited to \(list)", bundle: #bundle,
        comment: "An invitation on the Lists tab whose inviter was deleted: the list's name")
    case (.you, nil, true):
      return String(
        localized: "You're invited to this list", bundle: #bundle,
        comment: "An invitation on the list's page whose inviter was deleted")
    case (.child(let child), nil, false):
      return String(
        localized: "\(child) is invited to \(list)", bundle: #bundle,
        comment: "An invitation for the user's child on the Lists tab whose inviter was deleted: the child, the list")
    case (.child(let child), nil, true):
      return String(
        localized: "\(child) is invited to this list", bundle: #bundle,
        comment: "An invitation for the user's child on the list's page whose inviter was deleted: the child")
    }
  }
}
