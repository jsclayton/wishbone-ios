import SwiftUI
import WishboneSession

/// What a window shows: the signed-out screen while the device holds no session, the profile gate while the user's
/// profile is not confirmed, and then the tabs. See "What sits in front of the tabs" in `docs/spec.md`.
///
/// Every window reads the one `Device` that the app's composition root puts in the environment, so a sign-in in
/// one window signs in every window. Each window has its own place, and saves it for its scene.
public struct WindowRoot: View {
  @Environment(Device.self) private var device

  /// The window's place, as it was saved. See "What a window remembers" in `docs/spec.md`.
  @SceneStorage("WindowPlace") private var saved: Data?

  public init() {}

  public var body: some View {
    Group {
      if let session = device.session, !isWelcoming {
        Group {
          if session.needsProfileGate, let user = session.user {
            // In front of the tabs until the profile is confirmed, in every window.
            ProfileGateScreen(session: session, user: user)
          } else {
            PlacedFrame(session: session, saved: saved) { saved = $0 }
          }
        }
        // Another session model is another session: its windows start again.
        .id(ObjectIdentifier(session))
      } else {
        SignedOutScreen()
      }
    }
    // A session from an earlier launch shows what is saved at once. This sync brings it up to date.
    .task { await device.session?.sync() }
    .onChange(of: device.session == nil) {
      // A place is of one session. A window that sees the device sign out keeps none, so the next session starts
      // at Home. A window that opens on a signed-out device forgets nothing: the device also has no session while
      // the session keychain can't be read, and what another session saved is not restored anyway.
      if device.session == nil { saved = nil }
    }
  }

  /// Whether "Signed in as {name}" still shows.
  private var isWelcoming: Bool {
    if case .signedIn = device.signInState { true } else { false }
  }
}

/// The tabs, at the window's place. The place starts as the window saved it, and each change is saved.
private struct PlacedFrame: View {
  private let session: SessionModel
  private let save: (Data) -> Void
  @State private var place: WindowPlace

  init(session: SessionModel, saved: Data?, save: @escaping (Data) -> Void) {
    self.session = session
    self.save = save
    place = WindowPlace(restoring: saved, for: session.session) { $0.content(in: session) != .notFound }
  }

  var body: some View {
    TabFrame(session: session, place: $place)
      .onChange(of: place) { save(place.saved(for: session.session)) }
  }
}
