import StoreKit
import WishboneUI

/// The device's App Store storefront, from StoreKit, for the Support Wishbone row. This is the app's one file that
/// imports StoreKit, and no extension has it. See "Support Wishbone" in `docs/spec.md`.
struct AppStorefront: StorefrontSource {
  func current() async -> String? {
    await Storefront.current?.countryCode
  }

  func updates() -> AsyncStream<String> {
    AsyncStream { continuation in
      let task = Task {
        for await storefront in Storefront.updates {
          continuation.yield(storefront.countryCode)
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
