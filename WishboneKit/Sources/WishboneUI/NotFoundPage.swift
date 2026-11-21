import SwiftUI

/// The "not found" page: one page for everything that can't be shown. See `docs/screens/not-found.md`.
///
/// It is the same for a missing thing and a hidden thing, so it never says what kind of thing was asked for, or
/// why it is not there.
struct NotFoundPage: View {
  var body: some View {
    ContentUnavailableView {
      Label {
        Text("Not here", bundle: #bundle)
      } icon: {
        Image(systemName: "questionmark.circle")
      }
    } description: {
      Text("This is gone, or it isn't shared with you.", bundle: #bundle)
    }
    // The title and the line are one element.
    .accessibilityElement(children: .combine)
  }
}
