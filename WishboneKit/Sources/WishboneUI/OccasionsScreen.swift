import SwiftUI
import WishboneSession

/// The Occasions screen, pushed from the "Coming up" heading on Home: every occasion the user can see that has a
/// next date, soonest first, the user's own included. A tap on a row opens what it names: a person's page, the
/// user's primary list, or a shared occasion's page. See `docs/screens/occasions.md`.
///
/// Its states are the ones that every screen shares. With no occasion coming up, it says so.
///
/// A row is one element: the occasion, the date, the time left. The days count from the device's day, and change
/// at its midnight.
///
/// The admin's Shared occasions part and New shared occasion come later.
///
/// **Provisional.** Plain default: a system list in one column of readable width.
struct OccasionsScreen: View {
  let session: SessionModel

  /// The width of the window, for the list's column of readable width.
  @State private var width: CGFloat = 0
  @ScaledMetric(relativeTo: .body) private var readableWidth: CGFloat = 640

  var body: some View {
    TimelineView(MidnightSchedule()) { context in
      content(occasions: session.everyOccasion(today: context.date))
    }
    .navigationTitle(Text("Occasions", bundle: #bundle))
  }

  private func content(occasions: [HomeOccasion]) -> some View {
    List {
      Section {
        ForEach(occasions) { occasion in
          if let destination = occasion.destination {
            NavigationLink(value: destination.page) {
              ComingUpRow(occasion: occasion, session: session, showsDate: true)
            }
          } else {
            ComingUpRow(occasion: occasion, session: session, showsDate: true)
          }
        }
      } header: {
        Text("Coming up", bundle: #bundle)
          .font(.headline)
          .foregroundStyle(Color.primary)
          .textCase(nil)
          .accessibilityAddTraits(.isHeader)
      }
    }
    .contentMargins(.horizontal, max(0, (width - readableWidth) / 2), for: .scrollContent)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
    .sharedStates(of: session, hasRows: !occasions.isEmpty) {
      ContentUnavailableView {
        Text("No occasions are coming up.", bundle: #bundle)
      }
    }
  }
}
