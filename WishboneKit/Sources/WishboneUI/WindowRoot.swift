import SwiftUI
import WishboneSession

/// What a window shows: the signed-out screen while the device holds no session, and then the screen behind it.
/// See "What sits in front of the tabs" in `docs/spec.md`.
///
/// Every window reads the one `Device` that the app's composition root puts in the environment, so a sign-in in
/// one window signs in every window.
public struct WindowRoot: View {
  @Environment(Device.self) private var device

  public init() {}

  public var body: some View {
    Group {
      if let session = device.session, !isWelcoming {
        HomeStandInScreen(session: session)
      } else {
        SignedOutScreen()
      }
    }
    // A session from an earlier launch shows what is saved at once. This sync brings it up to date.
    .task { await device.session?.sync() }
  }

  /// Whether "Signed in as {name}" still shows.
  private var isWelcoming: Bool {
    if case .signedIn = device.signInState { true } else { false }
  }
}
