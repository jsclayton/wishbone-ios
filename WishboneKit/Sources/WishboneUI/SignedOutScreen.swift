import SwiftUI

/// The signed-out screen: the way in. See `docs/screens/signed-out.md`.
///
/// The controls are in place and do nothing yet.
public struct SignedOutScreen: View {
  /// The width of the column that holds the content. It grows with the text size.
  @ScaledMetric(relativeTo: .body) private var columnWidth: CGFloat = 440

  public init() {}

  public var body: some View {
    GeometryReader { window in
      ScrollView {
        VStack(spacing: 32) {
          Spacer(minLength: 0)
          title
          ways
          Spacer(minLength: 0)
          notice
        }
        .frame(maxWidth: columnWidth)
        .padding()
        // The notice sits at the foot of the window while the content fits. When it doesn't, the content scrolls
        // and the notice scrolls with it.
        .frame(maxWidth: .infinity, minHeight: window.size.height)
      }
    }
  }

  private var title: some View {
    Text("Wishbone", bundle: #bundle)
      .font(.largeTitle)
      .bold()
      .accessibilityAddTraits(.isHeader)
  }

  /// The two ways in, and the way to get help.
  private var ways: some View {
    VStack(spacing: 16) {
      Button {
      } label: {
        Text("Scan QR code", bundle: #bundle)
          .foregroundStyle(Color(.onAccent))
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)

      // The system paste button, so iOS shows no "allow paste" alert. The system gives it its words.
      PasteButton(payloadType: String.self) { _ in }

      Button {
      } label: {
        Text("I don't have a link", bundle: #bundle)
          .frame(minHeight: 44)
      }
    }
  }

  /// The diagnostics notice line.
  private var notice: some View {
    VStack(spacing: 0) {
      Text(
        "If Wishbone crashes, it sends a report to its developer, never anything from your family's lists.",
        bundle: #bundle
      )
      .multilineTextAlignment(.center)

      Button {
      } label: {
        Text("Diagnostics settings", bundle: #bundle)
          .frame(minHeight: 44)
      }
    }
    .font(.footnote)
  }
}

#Preview {
  SignedOutScreen()
}
