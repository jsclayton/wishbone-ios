import SwiftUI
import WishboneAPI
import WishboneSession

/// The signed-out screen: the way in. See `docs/screens/signed-out.md`.
///
/// Paste signs in. The scanner, the help sheet, and the diagnostics screen are not built yet, so their controls
/// are in place and do nothing.
public struct SignedOutScreen: View {
  @Environment(Device.self) private var device

  /// The width of the column that holds the content. It grows with the text size.
  @ScaledMetric(relativeTo: .body) private var columnWidth: CGFloat = 440

  public init() {}

  public var body: some View {
    GeometryReader { window in
      ScrollView {
        VStack(spacing: 32) {
          Spacer(minLength: 0)
          title
          message
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
    .onChange(of: device.signInState) {
      // The message is announced when it appears, and so is "Signed in as {name}".
      if let words { AccessibilityNotification.Announcement(words).post() }
    }
    .task(id: device.signInState) {
      // "Signed in as {name}" shows briefly, then the next screen.
      guard case .signedIn = device.signInState else { return }
      try? await Task.sleep(for: .seconds(1.5))
      device.finishWelcome()
    }
  }

  private var title: some View {
    Text("Wishbone", bundle: #bundle)
      .font(.largeTitle)
      .bold()
      .accessibilityAddTraits(.isHeader)
  }

  /// The message, when there is one, with Try again and Cancel under it while the device keeps a link.
  @ViewBuilder private var message: some View {
    if let words {
      VStack(spacing: 16) {
        if isSigningIn { ProgressView() }
        Text(words)
          .multilineTextAlignment(.center)
        if case .unreachable = device.signInState {
          Button {
            Task { await device.tryAgain() }
          } label: {
            Text("Try again", bundle: #bundle)
              .frame(minHeight: 44)
          }
          .buttonStyle(.bordered)
          Button {
            device.cancelSignIn()
          } label: {
            Text("Cancel", bundle: #bundle)
              .frame(minHeight: 44)
          }
        }
      }
    }
  }

  /// The words of the message for the state. Nil for the plain state.
  private var words: String? {
    switch device.signInState {
    case .plain:
      nil
    case .signingIn:
      String(localized: "Signing in…", bundle: #bundle)
    case .signedIn(let name):
      String(localized: "Signed in as \(name)", bundle: #bundle)
    case .linkInvalid:
      ErrorWords.linkInvalid
    case .notALoginLink:
      String(localized: "That isn't a Wishbone login link", bundle: #bundle)
    case .unreachable(let address):
      String(
        localized: "Can't reach \(address.text). Your link is kept. Try again when you're connected.", bundle: #bundle)
    case .noWishbone(let address):
      String(localized: "No Wishbone found at \(address.text)", bundle: #bundle)
    case .instanceTooOld(let address, let version, let minimum):
      String(
        localized:
          "\(address.text) runs Wishbone \(version). The app needs \(minimum) or later. Ask whoever runs it to update.",
        bundle: #bundle
      )
    case .refused(let refusal):
      ErrorWords.words(for: refusal)
    case .failed:
      ErrorWords.fault
    }
  }

  private var isSigningIn: Bool {
    device.signInState == .signingIn
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
      PasteButton(payloadType: String.self) { pasted in
        guard let text = pasted.first else { return }
        Task { await device.signIn(pasting: text) }
      }

      Button {
      } label: {
        Text("I don't have a link", bundle: #bundle)
          .frame(minHeight: 44)
      }
    }
    .disabled(isSigningIn)
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
