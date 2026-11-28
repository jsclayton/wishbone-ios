#if DEBUG
  import Foundation
  import WishboneAPI
  import WishboneSession
  import WishboneUI

  /// What a journey (an XCUITest of the whole app) asks of the app at launch. A journey launches the app with a
  /// login link passed in as if pasted. See "The simulator tier" in `docs/development.md`.
  ///
  /// A Debug build has this. A Release build has none of it.
  enum Journey {
    /// The login link to paste, in the launch environment.
    static let loginLinkVariable = "WISHBONE_JOURNEY_LOGIN_LINK"

    /// Set to start the launch signed out: the app first forgets the session of an earlier launch.
    static let signedOutVariable = "WISHBONE_JOURNEY_START_SIGNED_OUT"

    /// Set to a country code, such as "USA", to fix the App Store storefront at launch. StoreKit gives the
    /// simulator's storefront late, or not at all, so a journey would see the Support Wishbone row come and go.
    static let storefrontVariable = "WISHBONE_JOURNEY_STOREFRONT"

    /// Set to a number of seconds, such as "5", for the timer to sync that often in place of every 60 seconds. A
    /// journey that must see a sync while a screen shows waits seconds, not a minute.
    static let timerSecondsVariable = "WISHBONE_JOURNEY_TIMER_SECONDS"

    /// The clock of the timer that syncs: one whose every sleep is the launch environment's seconds, or `nil` for
    /// the system's clock.
    static var timerClock: (any Clock<Duration>)? {
      guard let text = ProcessInfo.processInfo.environment[timerSecondsVariable], let seconds = Int(text), seconds > 0
      else { return nil }
      return ShortTimerClock(interval: .seconds(seconds))
    }

    /// A clock whose every sleep is the interval, whatever it was asked for. The timer is the only one that sleeps
    /// on it.
    private struct ShortTimerClock: Clock {
      let interval: Duration
      private let base = ContinuousClock()

      var now: ContinuousClock.Instant { base.now }

      var minimumResolution: Duration { base.minimumResolution }

      func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
        try await base.sleep(for: interval)
      }
    }

    /// The storefront that the launch environment fixes, or `nil` to read StoreKit's.
    static var storefront: (any StorefrontSource)? {
      guard let code = ProcessInfo.processInfo.environment[storefrontVariable], !code.isEmpty else { return nil }
      return FixedStorefront(code: code)
    }

    /// A storefront that is the same from launch, and never changes.
    private struct FixedStorefront: StorefrontSource {
      let code: String

      func current() async -> String? { code }

      func updates() -> AsyncStream<String> {
        AsyncStream { $0.finish() }
      }
    }

    /// Forgets the session that an earlier journey left: the session keychain's item, which outlives the app on
    /// a simulator, and the local databases.
    static func startSignedOut(accessGroup: String) {
      guard ProcessInfo.processInfo.environment[signedOutVariable] != nil else { return }
      try? SystemSessionKeychain(accessGroup: accessGroup).delete()
      try? FileManager.default.removeItem(at: URL.applicationSupportDirectory.appending(path: "Sessions"))
    }

    /// Signs in with the login link of the launch environment, through the same call as the paste button.
    static func pasteLoginLink(into device: Device) async {
      guard let link = ProcessInfo.processInfo.environment[loginLinkVariable] else { return }
      await device.signIn(pasting: link)
    }
  }
#endif
