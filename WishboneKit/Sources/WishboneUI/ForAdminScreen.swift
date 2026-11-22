import SwiftUI
import WishboneSession

/// One of the admin's lists on the People page: All users, All groups, or Deactivated. See "For the admin" in
/// `docs/screens/people.md`.
///
/// - **All users** has every user by name, with "Deactivated" beside a deactivated user, and a search field that
///   filters by name. A search that finds nobody says so. It is the way to reach a user in no group.
/// - **All groups** has every group by name. A group's row opens nothing yet: the group's page comes later.
/// - **Deactivated** has the deactivated users.
///
/// A user's row pushes their page, and is one element: the name, then "Deactivated" when it applies. The lists
/// hold users and groups only.
///
/// **Provisional.** Plain default: a system list in one column of readable width, with the rows of the People page.
struct ForAdminScreen: View {
  /// `.allUsers`, `.allGroups`, or `.deactivatedUsers`. Any other page shows the not-found page.
  let page: Page
  let session: SessionModel

  @State private var search = ""

  /// The width of the window, for the list's column of readable width.
  @State private var width: CGFloat = 0
  @ScaledMetric(relativeTo: .body) private var readableWidth: CGFloat = 640

  var body: some View {
    let forAdmin = session.peoplePage.forAdmin
    Group {
      switch page {
      case .allGroups:
        List(forAdmin?.allGroups ?? []) { group in
          Text(group.name)
            .fixedSize(horizontal: false, vertical: true)
        }
        .navigationTitle(Text("All groups", bundle: #bundle))
      case .deactivatedUsers:
        users(forAdmin?.deactivated ?? [])
          .navigationTitle(Text("Deactivated", bundle: #bundle))
      case .allUsers:
        let found = forAdmin?.users(matching: search) ?? []
        users(found)
          .overlay {
            if found.isEmpty && !search.isEmpty {
              ContentUnavailableView {
                Text("No user has that name.", bundle: #bundle)
              }
            }
          }
          .searchable(text: $search, prompt: Text("Search users", bundle: #bundle))
          .navigationTitle(Text("All users", bundle: #bundle))
      default:
        NotFoundPage()
      }
    }
    .contentMargins(.horizontal, max(0, (width - readableWidth) / 2), for: .scrollContent)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
    .cantReachLine(of: session)
  }

  private func users(_ users: [UserRow]) -> some View {
    List(users) { user in
      NavigationLink(value: Page.user(id: user.id)) {
        PeopleRow(user: user)
      }
    }
  }
}
