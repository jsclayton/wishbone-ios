import UIKit

/// The share extension's entry point. It adds nothing yet: the activation rule in `Info.plist` matches nothing, so
/// iOS never offers Wishbone in a share sheet. If it ever opens, it closes at once.
///
/// The rule asks for an attachment of the type `com.codemonkeylabs.wishbone.never`, which nothing declares or shares.
/// It isn't `FALSEPREDICATE`, because App Store Connect refuses that value (ITMS-90362). The share extension's own
/// ticket gives it the real rule.
final class ShareViewController: UIViewController {
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    extensionContext?.completeRequest(returningItems: nil)
  }
}
