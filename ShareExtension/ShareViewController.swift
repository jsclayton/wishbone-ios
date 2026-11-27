import SwiftUI
import UIKit
import WishboneAPI
import WishboneSession
import WishboneUI

/// The share extension's entry point: it reads the one thing that the other app shared, builds the extension's
/// device from the shared Keychain item, and shows the add form. See `docs/screens/share-extension.md`.
///
/// The activation rule in `Info.plist` offers Wishbone for one web link or one text, and never for several things.
/// The extension links no diagnostics: it sends nothing.
final class ShareViewController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    let reading = Reading()
    let host = UIHostingController(
      rootView: Root(device: ShareDevice(.shareExtension()), reading: reading) { [weak self] in
        self?.extensionContext?.completeRequest(returningItems: nil)
      })
    addChild(host)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    host.didMove(toParent: self)
    let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
    Task { reading.shared = .read(await SharedReading.read(items)) }
  }

  /// What the other app shared, as it is read.
  @Observable
  final class Reading {
    var shared = SharedReading.reading
  }

  struct Root: View {
    let device: ShareDevice
    let reading: Reading
    let close: @MainActor () -> Void

    var body: some View {
      ShareExtensionScreen(device: device, shared: reading.shared, close: close)
    }
  }
}

extension ShareDevice.Setup {
  /// What the extension gives its device: the session keychain in the shared access group, the install marker in the
  /// app group's shared container, and the Darwin notification that tells the app of an add.
  static func shareExtension() -> ShareDevice.Setup {
    let info = Bundle.main
    let version = info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    let accessGroup = info.object(forInfoDictionaryKey: "WishboneKeychainAccessGroup") as? String ?? ""
    let appGroup = info.object(forInfoDictionaryKey: "WishboneAppGroup") as? String ?? ""
    return ShareDevice.Setup(
      userAgent: UserAgent(version: version, isPad: UIDevice.current.userInterfaceIdiom == .pad),
      keychain: SystemSessionKeychain(accessGroup: accessGroup),
      // A missing container is nil: the extension can't tell whether the session is left over.
      marker: FileInstallMarker(appGroup: appGroup),
      tellsTheApp: ItemAddedNotification(appGroup: appGroup))
  }
}
