import SwiftUI
import WishboneAPI
import WishboneSession

/// The signed-out screen: the way in. See `docs/screens/signed-out.md`.
///
/// Scan and paste sign in. "I don't have a link" opens the help sheet. The notice line at the foot opens Share
/// diagnostics as a sheet. Diagnostics start only once this screen has shown the notice.
public struct SignedOutScreen: View {
  @Environment(Device.self) private var device
  @Environment(\.diagnostics) private var diagnostics

  @State private var isShowingHelp = false
  @State private var isShowingDiagnostics = false

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
    .sheet(isPresented: $isShowingHelp) {
      LoginLinkHelpSheet()
    }
    .sheet(isPresented: $isShowingDiagnostics) {
      NavigationStack {
        ShareDiagnosticsScreen(place: .sheet)
      }
    }
    // The screen has shown the notice, so a person can turn diagnostics off before anything is sent. See "The
    // notice and the switch" in `docs/spec.md`.
    .onAppear { diagnostics?.noticeShown() }
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
        if device.keepsLink {
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
    case .tooManyTries:
      String(localized: "Too many tries. Wait a minute, then try again.", bundle: #bundle)
    case .certificateNotTrusted(let address):
      String(
        localized: "This device doesn't trust the certificate of \(address.text). Ask the person who runs Wishbone.",
        bundle: #bundle)
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
    case .signedOutUnreachable(let address):
      String(
        localized:
          "Signed out on this device. \(address.text) could not be reached, so this device still shows in your Devices list until you remove it there.",
        bundle: #bundle
      )
    }
  }

  private var isSigningIn: Bool {
    device.signInState == .signingIn
  }

  /// The two ways in, and the way to get help.
  private var ways: some View {
    VStack(spacing: 16) {
      #if os(iOS)
        ScanButton()
      #endif

      // The system paste button, so iOS shows no "allow paste" alert. The system gives it its words.
      PasteButton(payloadType: String.self) { pasted in
        guard let text = pasted.first else { return }
        Task { await device.signIn(pasting: text) }
      }

      Button {
        isShowingHelp = true
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
        isShowingDiagnostics = true
      } label: {
        Text("Diagnostics settings", bundle: #bundle)
          .frame(minHeight: 44)
      }
    }
    .font(.footnote)
  }
}
