import SwiftUI
import WishboneSession

/// The Home tab: the countdown to the next occasion, People, and Coming up. People has "Your children", then
/// "Your parents", then one part for each of the user's groups, each with its users as initials avatars. See
/// `docs/screens/home.md`.
///
/// Its states are the ones that every screen shares. "Nobody to see" is People's empty line, after a sync that
/// found nobody. With no occasion in the next 60 days, the countdown and Coming up each say so.
///
/// The countdown and Coming up count the days from the device's day, and change at its midnight.
///
/// A person is one button, whose words are the ones that show: the name, then "Deactivated" when it applies. The
/// avatar beside it is a drawing that VoiceOver skips, and a tap on it opens the person too.
///
/// A countdown occasion that opens a page is one button: a person's occasion opens their page, and a shared occasion
/// its page. A shared occasion also has "See who's on it", its own button, which opens the same page. A Coming up
/// row that opens a page is one link: a person's occasion opens their page, the user's own opens their primary list,
/// and a shared occasion opens its page. The "Coming up" heading is a link that pushes the Occasions screen.
///
/// **Provisional.** Plain default: a system list. The countdown is a card in the occasion's person color, one row
/// for each occasion. The "People" heading is a row that pushes the People page. Each
/// part is a section. Each person is a row, with the avatar and the name beside it, at every text size, and the rows
/// flow into as many columns as fit, in a system grid: one in a narrow window, more in a wide one.
struct HomeScreen: View {
  let session: SessionModel

  /// The pages pushed on Home. A tap on a person pushes their page.
  @Binding var pages: [Page]

  var body: some View {
    TimelineView(MidnightSchedule()) { context in
      content(occasions: session.homeOccasions(today: context.date))
    }
    .navigationTitle(Text("Home", bundle: #bundle))
  }

  private func content(occasions: HomeOccasions) -> some View {
    let people = session.people
    let hasRows = !people.isEmpty || !occasions.comingUp.isEmpty
    let state = session.screenState(hasRows: hasRows)
    // The headings show over their parts, and over their empty lines. While nothing is known, the state shows alone.
    let showsParts = state != .loading && state != .cantReach
    return List {
      if showsParts {
        countdown(occasions.countdown)
      }
      if showsParts {
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
      if showsParts {
        comingUp(occasions.comingUp)
      }
    }
    .sharedStates(of: session, hasRows: hasRows) {
      // The empty lines are in the list, under their headings.
      EmptyView()
    }
  }

  /// The countdown: one card row for each occasion on the next day, or the line that says there is none.
  @ViewBuilder private func countdown(_ occasions: [HomeOccasion]) -> some View {
    Section {
      if occasions.isEmpty {
        // In the primary color: the line can sit under the tab bar's glass, where the secondary color fails the
        // contrast rule.
        Text("Nothing in the next 60 days.", bundle: #bundle)
      }
      ForEach(occasions) { occasion in
        VStack(alignment: .leading, spacing: 4) {
          if let destination = occasion.destination {
            Button {
              open(destination)
            } label: {
              CountdownOccasion(occasion: occasion)
            }
            .buttonStyle(.plain)
          } else {
            CountdownOccasion(occasion: occasion)
          }
          if case .shared = occasion.whose {
            // Its own button, after the card's element.
            Button {
              open(.sharedOccasion(id: occasion.id))
            } label: {
              Text("See who's on it", bundle: #bundle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .underline()
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
          }
        }
        .listRowBackground(CountdownOccasion.background(of: occasion))
      }
    }
  }

  /// Coming up: its heading, which pushes the Occasions screen, then every occasion in the next 60 days, the
  /// soonest first, or its empty line.
  @ViewBuilder private func comingUp(_ occasions: [HomeOccasion]) -> some View {
    Section {
      // A row that pushes the Occasions screen, as the "People" heading pushes the People page.
      NavigationLink(value: Page.occasions) {
        Text("Coming up", bundle: #bundle)
          .font(.title2.weight(.bold))
      }
      .accessibilityAddTraits(.isHeader)
      if occasions.isEmpty {
        // In the primary color: the line can sit under the tab bar's glass, where the secondary color fails the
        // contrast rule.
        Text("Nothing in the next 60 days.", bundle: #bundle)
      }
      ForEach(occasions) { occasion in
        if let destination = occasion.destination {
          NavigationLink(value: destination.page) {
            ComingUpRow(occasion: occasion, session: session)
          }
        } else {
          ComingUpRow(occasion: occasion, session: session)
        }
      }
    }
  }

  /// Pushes the page that an occasion opens on Home.
  private func open(_ destination: HomeOccasion.Destination) {
    pages.append(destination.page)
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
