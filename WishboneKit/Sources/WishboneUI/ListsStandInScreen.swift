import SwiftUI

/// An empty screen that stands in for the Lists tab until it is built. See `docs/screens/lists.md`.
struct ListsStandInScreen: View {
  var body: some View {
    List {}
      .navigationTitle(Text("Lists", bundle: #bundle))
  }
}
