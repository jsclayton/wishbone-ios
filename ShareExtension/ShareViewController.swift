import UIKit

/// The share extension's entry point. It adds nothing yet: the activation rule in `Info.plist` matches nothing, so
/// iOS never offers Wishbone in a share sheet. If it ever opens, it closes at once.
final class ShareViewController: UIViewController {
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    extensionContext?.completeRequest(returningItems: nil)
  }
}
