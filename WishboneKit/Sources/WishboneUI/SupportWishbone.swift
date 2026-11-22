import Foundation
import Observation
import SwiftUI

/// The App Store storefront of the device, as StoreKit gives it. The app target's one file that imports StoreKit
/// gives the system's; a test gives a fake. Neither extension has one. See "Support Wishbone" in `docs/spec.md`.
public protocol StorefrontSource: Sendable {
  /// The current storefront's country code, ISO 3166-1 alpha-3 such as "USA", or `nil` when it is unknown.
  func current() async -> String?

  /// The country code of each new storefront, as it changes.
  func updates() -> AsyncStream<String>
}

/// Whether the Support Wishbone row may show on this device, and where it goes. See "Support Wishbone" in
/// `docs/spec.md` and `docs/screens/settings.md`.
///
/// The row shows only on the United States storefront, and only when the build has an address. Whether the user is a
/// child is the other half of the rule, in `SettingsSection.shown`. Diagnostics never record anything about support,
/// so this model has no reporter.
@MainActor
@Observable
public final class SupportWishbone {
  /// The storefront that allows a link to an outside payment: App Review guidelines 3.1.1(a) and 3.1.3.
  public static let allowedStorefront = "USA"

  /// The country code of the storefront, or `nil` while it is unknown.
  public private(set) var storefront: String?

  /// The support page, from the build's `WISHBONE_SUPPORT_URL`. `nil` means no row, for anyone.
  private let address: URL?

  @ObservationIgnored private let source: any StorefrontSource

  public init(source: any StorefrontSource, address: URL?) {
    self.source = source
    self.address = address
  }

  /// The support page when the row may show on this storefront, or `nil` when it may not: another storefront, an
  /// unknown one, or a build with no address.
  public var shownPage: URL? {
    guard storefront == Self.allowedStorefront else { return nil }
    return address
  }

  /// Reads the current storefront, then follows each change until the task is cancelled. Each window follows, so
  /// closing one window leaves the others following.
  public func follow() async {
    storefront = await source.current()
    for await code in source.updates() {
      storefront = code
    }
  }

  /// A tap on the row: opens the support page in the default browser, at once, with no screen in between. It
  /// records nothing.
  public func tap(_ open: (URL) -> Void) {
    if let page = shownPage { open(page) }
  }
}

extension EnvironmentValues {
  /// The app's Support Wishbone rule. `nil` in an extension, and then there is no row.
  @Entry public var supportWishbone: SupportWishbone? = nil
}
