import SwiftUI
import WishboneSession

/// A shared occasion's page, the same for everyone: its name, its date and the days left, "Everyone" when it is for
/// everyone, and the users it applies to whom the user can see. Each user is marked "{n} from you" or "Nothing
/// yet", and pushes their page. The admin also sees the names of its groups. See `docs/screens/occasions.md`.
///
/// The counts are the user's own open gifts, and show only here, inside the app.
///
/// A user's row is one element: the name, then the count. The occasion's symbol is decoration.
///
/// The admin's Edit and Delete come later.
///
/// **Provisional.** Plain default: a system list in one column of readable width.
struct SharedOccasionScreen: View {
  let id: String
  let session: SessionModel

  /// The width of the window, for the list's column of readable width.
  @State private var width: CGFloat = 0
  @ScaledMetric(relativeTo: .body) private var readableWidth: CGFloat = 640

  var body: some View {
    TimelineView(MidnightSchedule()) { context in
      if let page = session.sharedOccasionPage(id: id, today: context.date) {
        content(page)
      } else {
        NotFoundPage()
      }
    }
  }

  private func content(_ page: SharedOccasionPage) -> some View {
    List {
      Section {
        header(page)
      }
      Section {
        if page.people.isEmpty {
          Text("Nobody you can see is on this occasion.", bundle: #bundle)
            .foregroundStyle(.secondary)
        }
        ForEach(page.people) { person in
          NavigationLink(value: Page.user(id: person.user.id)) {
            PersonRow(person: person)
          }
        }
      }
    }
    .contentMargins(.horizontal, max(0, (width - readableWidth) / 2), for: .scrollContent)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
    .cantReachLine(of: session)
    .navigationTitle(Text(page.name))
  }

  /// The occasion's name, its date and the days left, and who it reaches. It is one element.
  private func header(_ page: SharedOccasionPage) -> some View {
    HStack(alignment: .top, spacing: 12) {
      SharedOccasionSymbol()
      VStack(alignment: .leading, spacing: 2) {
        Text(page.name)
          .font(.title3.weight(.bold))
        if let date = page.date {
          Text(OccasionDateWords.monthAndDay(date))
        }
        if let timeLeft = page.timeLeft {
          TimeLeftWords(timeLeft: timeLeft)
            .foregroundStyle(.secondary)
        }
        if page.isEveryone {
          Text("Everyone", bundle: #bundle)
        }
        ForEach(page.groupNames, id: \.self) { name in
          Text(name)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

/// A user on a shared occasion: the avatar, the name, then "{n} from you" or "Nothing yet". It is one element: the
/// name, then the count.
private struct PersonRow: View {
  let person: SharedOccasionPage.Person

  var body: some View {
    HStack(spacing: 12) {
      PersonAvatar(user: person.user, size: .small)
      VStack(alignment: .leading, spacing: 2) {
        PersonName(user: person.user)
        Group {
          if person.fromYou == 0 {
            Text("Nothing yet", bundle: #bundle)
          } else {
            Text("\(person.fromYou) from you", bundle: #bundle)
          }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}
