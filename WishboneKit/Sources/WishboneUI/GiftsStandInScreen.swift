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
      // The words are a sentence, so they are the view's description, which wraps, and not its title.
      ContentUnavailableView {
        EmptyView()
      } description: {
        Text("You aren't getting anything yet. Open someone on Home and tap I'll get this.", bundle: #bundle)
      }
    }
    .navigationTitle(Text("Gifts", bundle: #bundle))
  }
}
