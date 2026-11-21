import SwiftUI
import WishboneSession

/// A plain screen that stands in for Home until Home is built: the titles of the items on the user's primary
/// list, read from the local copy. Its states are the ones that every screen shares (see "What every screen
/// shares" in `docs/screens/README.md`).
struct HomeStandInScreen: View {
  let session: SessionModel

  var body: some View {
    List {
      ForEach(session.primaryListItems) { item in
        Text(item.title)
      }
    }
    .sharedStates(of: session, hasRows: !session.primaryListItems.isEmpty) {
      ContentUnavailableView {
        Text("Nothing on this list yet.", bundle: #bundle)
      }
    }
    .navigationTitle(Text(session.primaryList?.name ?? session.user?.name ?? ""))
  }
}
