import SwiftUI
import WishboneSession

/// The Home tab. For now it holds People: "Your children", then "Your parents", then one part for each of the
/// user's groups, each with its users as initials avatars. The countdown and Coming up come later. See
/// `docs/screens/home.md`.
///
/// Its states are the ones that every screen shares. "Nobody to see" is People's empty line, after a sync that
/// found nobody.
///
/// **Provisional.** Plain default: a system list. The "People" heading is a row that pushes the People page. Each
/// part is a section, whose avatars flow into as many columns as fit. At the largest text sizes, the avatars
/// become rows with the name beside each.
struct HomeScreen: View {
  let session: SessionModel

  /// The pages pushed on Home. A tap on a person pushes their page.
  @Binding var pages: [Page]

  @Environment(\.dynamicTypeSize) private var textSize

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
          if textSize.isAccessibilitySize {
            ForEach(part.users) { user in
              NavigationLink(value: Page.user(id: user.id)) {
                HStack(spacing: 12) {
                  PersonAvatar(user: user)
                  PersonName(user: user)
                }
              }
            }
          } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), alignment: .top)], alignment: .leading) {
              ForEach(part.users) { user in
                Button {
                  pages.append(.user(id: user.id))
                } label: {
                  VStack(spacing: 6) {
                    PersonAvatar(user: user)
                    PersonName(user: user, alignment: .center)
                  }
                  .frame(maxWidth: .infinity, minHeight: 44)
                  .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
              }
            }
            .padding(.vertical, 8)
          }
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
}

/// A part's heading: "Your children", "Your parents", or the group's name, with "through {group}" for a group that
/// the user is in by nesting.
private struct PartHeading: View {
  let part: PeoplePart

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      switch part.kind {
      case .children:
        Text("Your children", bundle: #bundle)
      case .parents:
        Text("Your parents", bundle: #bundle)
      case .group(let group, let through):
        Text(group.name)
        if let through {
          Text("through \(through.name)", bundle: #bundle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
    }
    .font(.headline)
    .foregroundStyle(.primary)
    .textCase(nil)
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}
