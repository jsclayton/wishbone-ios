import SwiftUI

/// The Add screen: the start of adding an item. See `docs/screens/add.md`.
///
/// Only the system search field and its prompt are built. The three ways in, and the search itself, are not.
struct AddScreen: View {
  /// The text in the field. The window keeps it, so it is still there after a change of tab.
  @Binding var search: String

  @FocusState private var isFieldFocused: Bool

  var body: some View {
    List {}
      .navigationTitle(Text("Add", bundle: #bundle))
      .searchable(text: $search, prompt: Text("Paste a link or type what you want", bundle: #bundle))
      .searchFocused($isFieldFocused)
      // The screen opens with its field ready. Where the system shows the field as a button, in a tab bar at the
      // top of a wide window, the field opens with a tap on that button.
      .onAppear { isFieldFocused = true }
  }
}
