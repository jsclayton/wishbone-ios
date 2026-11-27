import SwiftUI
import WishboneSession

/// Invite: the users whom the user can invite to the list, by name, with their avatars, in a sheet. A tap invites
/// that user at once, as an unsent change, and the sheet stays open for another: the user leaves the sheet, and the
/// invitation shows on the list's page in every window. Nothing asks first, because the user can withdraw it. The
/// users come from the copy, by the server's rule: whom the user sees, with the admin's access not counted. See
/// Invite in `docs/screens/list.md`.
///
/// **Provisional.** Plain default: a system list in a sheet, each row the avatar and the name, with Done in the
/// toolbar.
struct InviteSheet: View {
  let listID: String
  let session: SessionModel

  @Environment(\.dismiss) private var dismiss

  /// The users whose invite is being saved: their rows go at once, and a second tap invites nobody twice.
  @State private var inviting: Set<String> = []

  var body: some View {
    NavigationStack {
      let users = session.invitableUsers(toList: listID).filter { !inviting.contains($0.id) }
      List {
        if users.isEmpty {
          // The primary color: the system's secondary gray is below 4.5:1 on the row.
          Text(
            "There's nobody else to invite. You can invite people you can see who aren't on this list.",
            bundle: #bundle)
        }
        ForEach(users) { user in
          Button {
            invite(user)
          } label: {
            HStack(spacing: 12) {
              PersonAvatar(user: user, size: .small)
              Text(user.name)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // In the primary color: each row is a choice, not a link.
            .foregroundStyle(.primary)
            .contentShape(.rect)
          }
          .accessibilityLabel(Text(user.name))
        }
      }
      .navigationTitle(Text("Invite to \(session.list(id: listID)?.name ?? "")", bundle: #bundle))
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button {
            dismiss()
          } label: {
            Text("Done", bundle: #bundle)
          }
        }
      }
    }
  }

  private func invite(_ user: UserRow) {
    guard !inviting.contains(user.id) else { return }
    inviting.insert(user.id)
    Task {
      await session.invite(user.id, toList: listID)
      inviting.remove(user.id)
    }
  }
}

/// One of the list's other pending invitations, on its page: the invited user's avatar and "Grandpa · invited by
/// Mom", and Withdraw, from its `can_delete`, with no confirmation. With no inviter, who was deleted since, only the
/// name shows.
///
/// It is one element: the line, with the action Withdraw. The button is on screen too.
///
/// **Provisional.** Plain default: a row with the avatar, the line, and a Withdraw button at the trailing edge.
struct OtherInvitationRow: View {
  let invitation: ListInvitation
  let session: SessionModel

  var body: some View {
    let line = InvitationWords.other(invited: invitation.user.name, inviter: invitation.inviterName)
    HStack(spacing: 12) {
      PersonAvatar(user: invitation.user, size: .small)
      Text(line)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
      if invitation.canWithdraw {
        Button(action: withdraw) {
          Text("Withdraw", bundle: #bundle)
        }
        .buttonStyle(.bordered)
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(line))
    .accessibilityActions {
      if invitation.canWithdraw {
        Button(action: withdraw) {
          Text("Withdraw", bundle: #bundle)
        }
      }
    }
  }

  private func withdraw() {
    Task { await session.withdrawInvitation(invitation.id) }
  }
}
