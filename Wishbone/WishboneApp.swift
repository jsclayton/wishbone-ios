import SwiftUI
import WishboneAPI
import WishboneSession
import WishboneUI

@main
struct WishboneApp: App {
  /// The one device of the app. Every window scene reads it from the environment.
  @State private var device = Device(.app)

  var body: some Scene {
    WindowGroup {
      WindowRoot()
        .environment(device)
        #if DEBUG
          .task { await Journey.pasteLoginLink(into: device) }
        #endif
    }
  }
}

extension Device.Setup {
  /// What the app gives its device: the session keychain in the shared access group, and the database in the
  /// app's own Application Support folder.
  static var app: Device.Setup {
    let info = Bundle.main
    let version = info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    let accessGroup = info.object(forInfoDictionaryKey: "WishboneKeychainAccessGroup") as? String ?? ""
    #if DEBUG
      Journey.startSignedOut(accessGroup: accessGroup)
    #endif
    return Device.Setup(
      userAgent: UserAgent(version: version, isPad: UIDevice.current.userInterfaceIdiom == .pad),
      keychain: SystemSessionKeychain(accessGroup: accessGroup),
      storage: .folder(.applicationSupportDirectory)
    )
  }
}
