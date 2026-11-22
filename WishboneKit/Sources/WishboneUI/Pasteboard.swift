import Foundation
import UniformTypeIdentifiers

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

/// The system's pasteboard, for Copy link. It takes a web address and nothing else, so what it carries is only
/// the address: see "Secrecy" in `docs/screens/item.md`.
enum Pasteboard {
  /// Puts the address on the pasteboard, as a link and as its text, so that it pastes into any app.
  static func copy(_ url: URL) {
    #if canImport(UIKit)
      UIPasteboard.general.items = [
        [UTType.url.identifier: url, UTType.plainText.identifier: url.absoluteString]
      ]
    #else
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(url.absoluteString, forType: .URL)
      pasteboard.setString(url.absoluteString, forType: .string)
    #endif
  }
}
