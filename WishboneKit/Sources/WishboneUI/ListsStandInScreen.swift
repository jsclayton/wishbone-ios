import SwiftUI
import WishboneSession

/// A plain screen that stands in for the Lists tab until it is built: the names of the lists in the local copy.
/// Its states are the ones that every screen shares. See `docs/screens/lists.md`.
struct ListsStandInScreen: View {
  let session: SessionModel

  var body: some View {
    List {
      ForEach(session.lists) { list in
        Text(list.name)
      }
    }
    .sharedStates(of: session, hasRows: !session.lists.isEmpty) {
      // Every user has a primary list, so the real tab is never empty after a sync. The stand-in says so anyway.
      ContentUnavailableView {
        Text("No lists yet.", bundle: #bundle)
      }
    }
    .navigationTitle(Text("Lists", bundle: #bundle))
  }
}
