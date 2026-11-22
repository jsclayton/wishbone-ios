import SwiftUI
import WishboneSession

/// The People page: everyone whom the user sees, by group. "Your children", then "Your parents", then one part for
/// each of the user's groups, with "through {group}" for a group that the user is in by nesting. A tap on a row
/// pushes the user's page. For the admin, "For the admin" follows, with rows that push All users, All groups, and
/// Deactivated. Deactivated is hidden when nobody is deactivated. The add menu comes later. See
/// `docs/screens/people.md`.
///
/// Its states are the ones that every screen shares. "Nobody to see" says so, as Home does, after a sync that found
/// nobody.
///
/// A row is one element: the name with the last name, then "Deactivated" when it applies. A group's heading is
/// plain text, and a heading for the VoiceOver rotor.
///
/// **Provisional.** Plain default: a system list in one column of readable width. Each part is a section, and each
/// row has the avatar, then the name with the last name.
struct PeopleScreen: View {
  let session: SessionModel

  /// The width of the window, for the list's column of readable width.
  @State private var width: CGFloat = 0
  @ScaledMetric(relativeTo: .body) private var readableWidth: CGFloat = 640

  var body: some View {
    let page = session.peoplePage
    List {
      ForEach(page.parts) { part in
        Section {
          ForEach(part.users) { user in
            NavigationLink(value: Page.user(id: user.id)) {
              PeopleRow(user: user)
            }
          }
        } header: {
          PartHeading(part: part)
        }
      }
      if let forAdmin = page.forAdmin {
        Section {
          NavigationLink(value: Page.allUsers) {
            Text("All users", bundle: #bundle)
          }
          NavigationLink(value: Page.allGroups) {
            Text("All groups", bundle: #bundle)
          }
          if !forAdmin.deactivated.isEmpty {
            NavigationLink(value: Page.deactivatedUsers) {
              Text("Deactivated", bundle: #bundle)
            }
          }
        } header: {
          Text("For the admin", bundle: #bundle)
            .font(.headline)
            .foregroundStyle(.primary)
            .textCase(nil)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
        }
      }
    }
    .contentMargins(.horizontal, max(0, (width - readableWidth) / 2), for: .scrollContent)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
    .sharedStates(of: session, hasRows: !page.isEmpty) {
      ContentUnavailableView {
        Text("Nobody is here yet. The admin adds people to your groups.", bundle: #bundle)
      }
    }
    .navigationTitle(Text("People", bundle: #bundle))
  }
}

/// A user's row on the People page: the avatar, then the name with the last name, and "Deactivated" when it
/// applies. It is one element, whose words are the ones that show.
struct PeopleRow: View {
  let user: UserRow

  var body: some View {
    HStack(spacing: 12) {
      PersonAvatar(user: user)
      VStack(alignment: .leading, spacing: 2) {
        Text(user.fullName)
          .fixedSize(horizontal: false, vertical: true)
        if user.isDeactivated {
          Text("Deactivated", bundle: #bundle)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }
}
