import SwiftUI

/// An empty screen that stands in for the Gifts tab until it is built. See `docs/screens/gifts.md`.
struct GiftsStandInScreen: View {
  var body: some View {
    List {}
      .navigationTitle(Text("Gifts", bundle: #bundle))
  }
}
