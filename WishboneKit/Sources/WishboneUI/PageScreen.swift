import SwiftUI
import WishboneSession

/// A pushed page: a list's page, a user's page, an item's page, a gift's page, the People page, one of the admin's
/// lists on it, the Occasions screen, or a shared occasion's page.
/// A page whose thing is not in the copy is the "not found" page, also when the thing goes away while the page shows.
struct PageScreen: View {
  let page: Page
  let session: SessionModel

  /// The window's pages on the tab, for a page that pushes another from a link in its text.
  @Binding var pages: [Page]

  var body: some View {
    switch page.content(in: session) {
    case .list(let id):
      if let list = session.listPage(id: id) {
        ListPageScreen(page: list, session: session, pages: $pages)
      } else {
        NotFoundPage()
      }
    case .user(let id):
      if let user = session.userPage(id: id) {
        UserPageScreen(page: user, session: session, pages: $pages)
      } else {
        NotFoundPage()
      }
    case .item(let id):
      if let item = session.itemPage(id: id) {
        ItemPageScreen(page: item, session: session, pages: $pages)
      } else {
        NotFoundPage()
      }
    case .gift(let id):
      if let gift = session.giftPage(id: id) {
        GiftPageScreen(page: gift, session: session, pages: $pages)
      } else {
        NotFoundPage()
      }
    case .people: PeopleScreen(session: session)
    case .forAdmin(let page): ForAdminScreen(page: page, session: session)
    case .occasions: OccasionsScreen(session: session)
    case .sharedOccasion(let id):
      if session.sharedOccasionPage(id: id) != nil {
        SharedOccasionScreen(id: id, session: session)
      } else {
        NotFoundPage()
      }
    case .notFound: NotFoundPage()
    }
  }
}
