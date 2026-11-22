import SwiftUI
import WishboneSession

/// The Home tab. For now it holds People: "Your children", then "Your parents", then one part for each of the
/// user's groups, each with its users as initials avatars. The countdown and Coming up come later. See
/// `docs/screens/home.md`.
///
/// Its states are the ones that every screen shares. "Nobody to see" is People's empty line, after a sync that
/// found nobody.
///
/// A person is one button, whose words are the ones that show: the name, then "Deactivated" when it applies. The
/// avatar beside it is a drawing that VoiceOver skips, and a tap on it opens the person too.
///
/// **Provisional.** Plain default: a system list. The "People" heading is a row that pushes the People page. Each
/// part is a section. Each person is a row, with the avatar and the name beside it, at every text size, and the rows
/// flow into as many columns as fit, in a system grid: one in a narrow window, more in a wide one.
struct HomeScreen: View {
  let session: SessionModel

  /// The pages pushed on Home. A tap on a person pushes their page.
  @Binding var pages: [Page]

  var body: some View {
    let people = session.people
    let state = session.screenState(hasRows: !people.isEmpty)
    List {
      // The heading shows over People, and over its empty line. While nothing is known, the state shows alone.
      if state != .loading && state != .cantReach {
        Section {
          NavigationLink(value: Page.people) {
            Text("People", bundle: #bundle)
              .font(.title2.weight(.bold))
          }
          .accessibilityAddTraits(.isHeader)
          if people.isEmpty {
            Text("Nobody is here yet. The admin adds people to your groups.", bundle: #bundle)
              .foregroundStyle(.secondary)
          }
        }
      }
      ForEach(people) { part in
        Section {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(part.users) { user in
              HStack(spacing: 12) {
                avatar(of: user)
                name(of: user)
              }
            }
          }
          .padding(.vertical, 8)
        } header: {
          PartHeading(part: part)
        }
      }
    }
    .sharedStates(of: session, hasRows: !people.isEmpty) {
      // People's empty line is in the list, under its heading.
      EmptyView()
    }
    .navigationTitle(Text("Home", bundle: #bundle))
  }

  /// A person's avatar. A tap on it opens the person, as a tap on the name does. VoiceOver skips it, and reads the
  /// name's button.
  private func avatar(of user: UserRow) -> some View {
    PersonAvatar(user: user)
      .contentShape(.circle)
      .onTapGesture { open(user) }
  }

  /// A person's name, as the button that opens them. The button holds only words, so its element is the name, then
  /// "Deactivated" when it applies, and its text grows with the text size.
  private func name(of user: UserRow) -> some View {
    Button {
      open(user)
    } label: {
      PersonName(user: user)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
  }

  /// Pushes the user's page on Home.
  private func open(_ user: UserRow) {
    pages.append(.user(id: user.id))
  }
}
