import SwiftUI
import WishboneAPI
import WishboneSession
import WishboneUI

@main
struct WishboneApp: App {
  /// The one device of the app. Every window scene reads it from the environment.
  @State private var device = Device(.app)

  /// The phase of the whole app: active while any window is in the foreground.
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      WindowRoot()
        .environment(device)
        #if DEBUG
          .task { await Journey.pasteLoginLink(into: device) }
        #endif
    }
    .onChange(of: scenePhase) { _, phase in
      // Each time the app comes to the foreground, the session syncs and reports the time zone. Nothing waits for
      // it. See "Time zone" in `docs/spec.md`.
      guard phase == .active, let session = device.session else { return }
      Task { await session.cameToForeground() }
    }
  }
}

extension Device.Setup {
  /// What the app gives its device: the session keychain in the shared access group, the install marker in the app
  /// group's shared container, and the database in the app's own Application Support folder.
  static var app: Device.Setup {
    let info = Bundle.main
    let version = info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    let accessGroup = info.object(forInfoDictionaryKey: "WishboneKeychainAccessGroup") as? String ?? ""
    let appGroup = info.object(forInfoDictionaryKey: "WishboneAppGroup") as? String ?? ""
    #if DEBUG
      Journey.startSignedOut(accessGroup: accessGroup)
    #endif
    return Device.Setup(
      userAgent: UserAgent(version: version, isPad: UIDevice.current.userInterfaceIdiom == .pad),
      keychain: SystemSessionKeychain(accessGroup: accessGroup),
      marker: installMarker(appGroup: appGroup),
      storage: .folder(.applicationSupportDirectory)
    )
  }

  /// The install marker in the app group's shared container. A build with no app group, which is a fault, keeps
  /// the marker in the app's own Application Support folder: deleting the app deletes that folder too, so the app
  /// still starts signed out after a reinstall.
  private static func installMarker(appGroup: String) -> FileInstallMarker {
    if let marker = FileInstallMarker(appGroup: appGroup) { return marker }
    Log.fault(.session, "The app group's shared container is missing.")
    return FileInstallMarker(container: .applicationSupportDirectory)
  }
}
