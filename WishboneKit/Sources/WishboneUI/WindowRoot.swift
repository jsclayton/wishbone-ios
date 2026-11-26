import SwiftUI
import WishboneAPI
import WishboneSession

/// What a window shows: the signed-out screen while the device holds no session, a version block while the app and
/// the instance can't work together, the profile gate while the user's profile is not confirmed, and then the tabs.
/// See "What sits in front of the tabs" in `docs/spec.md`.
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
          if let block = session.versionBlock {
            // In place of everything else, in every window. When it goes, the tabs start again at the saved place.
            VersionBlockScreen(block: block, address: session.session.instance, way: .signedIn(session))
          } else if session.needsProfileGate, let user = session.user {
            // In front of the tabs until the profile is confirmed, in every window.
            ProfileGateScreen(session: session, user: user)
          } else {
            PlacedFrame(session: session, saved: saved) { saved = $0 }
          }
        }
        // Each time the window comes to the foreground, the session syncs. A session from an earlier launch shows
        // what is saved at once, and this brings it up to date.
        .reportsForeground(to: session)
        // Every screen of the session shows the instance's images through its cache.
        .environment(\.sessionImages, session.images)
        // Another session model is another session: its windows start again.
        .id(ObjectIdentifier(session))
      } else if let (block, address) = signInBlock {
        // During sign-in, a version block shows over the signed-out screen, with Back.
        VersionBlockScreen(block: block, address: address, way: .signingIn)
      } else {
        SignedOutScreen()
      }
    }
    .onChange(of: device.session == nil) {
      // A place is of one session. A window that sees the device sign out keeps none, so the next session starts
      // at Home. A window that opens on a signed-out device forgets nothing: the device also has no session while
      // the session keychain can't be read, and what another session saved is not restored anyway.
      if device.session == nil { saved = nil }
    }
  }

  /// The version block that a sign-in met, and the instance that it was for. Nil when the sign-in met none.
  private var signInBlock: (VersionBlock, InstanceAddress)? {
    switch device.signInState {
    case .instanceTooOld(let address, let version, let minimum):
      (.instanceTooOld(version: version, minimum: minimum), address)
    case .appTooOld(let address):
      (.appTooOld, address)
    default:
      nil
    }
  }

  /// Whether "Signed in as {name}" still shows.
  private var isWelcoming: Bool {
    if case .signedIn = device.signInState { true } else { false }
  }
}

/// The tabs, at the window's place. The place starts as the window saved it, and each change is saved.
///
/// Each place that the window opens leaves a breadcrumb of its kind, never of what it shows.
private struct PlacedFrame: View {
  @Environment(\.diagnosticsReporter) private var diagnostics
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
      .onChange(of: place) { earlier, place in
        save(place.saved(for: session.session))
        // The server's ID in the place of a stand-in opens no new place.
        if let kind = place.opened(since: earlier.replacingStandIns(session.replacedStandIns)) {
          diagnostics.leave(.placeOpened(kind))
        }
      }
      // An item that the user added by hand, and a list that New list made, show by the server's ID once the instance
      // has them. See `StandIn`.
      .onChange(of: session.replacedStandIns, initial: true) { _, standIns in
        place.replaceStandIns(standIns)
      }
  }
}
