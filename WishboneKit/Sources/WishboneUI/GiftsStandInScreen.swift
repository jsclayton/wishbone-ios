import SwiftUI
import WishboneSession

/// A plain screen that stands in for the Gifts tab until it is built: the titles of the gifts in Giving, read from
/// the local copy. Its states are the ones that every screen shares. See `docs/screens/gifts.md`.
struct GiftsStandInScreen: View {
  let session: SessionModel

  var body: some View {
    List {
      ForEach(session.giving) { gift in
        Text(gift.title)
      }
    }
    .sharedStates(of: session, hasRows: !session.giving.isEmpty) {
      // The stand-in's own words. The Gifts tab brings the words of its spec for each empty part.
      ContentUnavailableView {
        Text("No gifts yet.", bundle: #bundle)
      }
    }
    .navigationTitle(Text("Gifts", bundle: #bundle))
  }
}
