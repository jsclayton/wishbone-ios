import SwiftUI
import WishboneSession

/// A pushed page. Until the real pages are built, a list, a user, and People are each one plain page with the
/// thing's name. A page whose thing is not in the copy is the "not found" page, also when the thing goes away
/// while the page shows.
struct PageScreen: View {
  let page: Page
  let session: SessionModel

  var body: some View {
    switch page.content(in: session) {
    case .list(let list): standIn(named: Text(list.name))
    case .user(let user): standIn(named: Text(user.name))
    case .people: standIn(named: Text("People", bundle: #bundle))
    case .notFound: NotFoundPage()
    }
  }

  /// A plain page with only the thing's name. The real page replaces it.
  private func standIn(named name: Text) -> some View {
    List {}
      .navigationTitle(name)
  }
}
