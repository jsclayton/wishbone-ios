import SwiftUI
import WishboneSession

/// A pushed page. A user's page is built. Until the other pages are, a list and People are each one plain page with
/// the thing's name. A page whose thing is not in the copy is the "not found" page, also when the thing goes away
/// while the page shows.
struct PageScreen: View {
  let page: Page
  let session: SessionModel

  var body: some View {
    switch page.content(in: session) {
    case .list(let list): standIn(named: Text(list.name))
    case .user(let id):
      if let user = session.userPage(id: id) {
        UserPageScreen(page: user, session: session)
      } else {
        NotFoundPage()
      }
    case .people: standIn(named: Text("People", bundle: #bundle))
    case .notFound: NotFoundPage()
    }
  }

  /// A plain page with only the thing's name. The real page replaces it.
  private func standIn(named name: Text) -> some View {
    List {}
      .cantReachLine(of: session)
      .navigationTitle(name)
  }
}
