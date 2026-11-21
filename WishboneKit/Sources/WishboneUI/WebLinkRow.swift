import SwiftUI

/// A row that is a web link: its words, and the link-out arrow. It opens the address in the default browser, never
/// in the app. See "Web links" in `docs/screens/README.md` and in `docs/spec.md`.
///
/// VoiceOver reads it as one element: its words, then "opens in browser". Voice Control takes its words alone, the
/// words on screen.
struct WebLinkRow: View {
  let title: String
  let destination: URL

  var body: some View {
    // The system opens a web address in the default browser.
    Link(destination: destination) {
      HStack {
        Text(title)
        Spacer()
        // The arrow's words follow the row's, so VoiceOver reads "{words}, opens in browser".
        Image(systemName: "arrow.up.right")
          .foregroundStyle(.secondary)
          .accessibilityLabel(Text("opens in browser", bundle: #bundle))
      }
      .contentShape(.rect)
    }
    .accessibilityElement(children: .combine)
    .accessibilityInputLabels([Text(title)])
  }
}
