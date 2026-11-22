import Foundation
import Testing
import WishboneUI

/// The Support Wishbone row: the storefront, the child rule, the build's address, and the tap. The storefront is a
/// fake. See "Support Wishbone" in `docs/spec.md`, and `docs/screens/settings.md`.
@Suite("Support Wishbone", .timeLimit(.minutes(1)))
@MainActor
struct SupportWishboneTests {
  /// The address in the tests: the build's own.
  static let page = URL(string: "https://buymeacoffee.com/jsclayton")!

  @Test("The row shows on the US storefront, not on another or an unknown one, and follows a change")
  func storefront() async {
    let source = FakeStorefront(current: nil)
    let support = SupportWishbone(source: source, address: Self.page)
    let following = Task { await support.follow() }
    defer { following.cancel() }

    // Unknown: no row.
    await until { source.isFollowed }
    #expect(support.storefront == nil)
    #expect(support.shownPage == nil)
    #expect(SettingsSection.shown(isAdmin: false, hasParents: false, support: support.shownPage).count == 5)

    // The United States: the row, between Share diagnostics and About.
    source.change(to: "USA")
    await until { support.storefront == "USA" }
    #expect(support.shownPage == Self.page)
    #expect(
      SettingsSection.shown(isAdmin: false, hasParents: false, support: support.shownPage)
        == [.signedIn, .signInAndDevices, .reminders, .shareDiagnostics, .supportWishbone, .about])
    #expect(
      SettingsSection.shown(isAdmin: true, hasParents: false, support: support.shownPage)
        == [.signedIn, .signInAndDevices, .reminders, .shareDiagnostics, .forTheAdmin, .supportWishbone, .about])

    // Another storefront: the row goes.
    source.change(to: "CAN")
    await until { support.storefront == "CAN" }
    #expect(support.shownPage == nil)
    #expect(
      !SettingsSection.shown(isAdmin: false, hasParents: false, support: support.shownPage).contains(.supportWishbone))

    // A storefront that is the USA at launch shows the row from the start.
    let atLaunch = SupportWishbone(source: FakeStorefront(current: "USA"), address: Self.page)
    let followingAtLaunch = Task { await atLaunch.follow() }
    defer { followingAtLaunch.cancel() }
    await until { atLaunch.storefront == "USA" }
    #expect(atLaunch.shownPage == Self.page)
  }

  @Test("A user who has parents never sees the row, on any storefront")
  func child() async throws {
    let support = SupportWishbone(source: FakeStorefront(current: "USA"), address: Self.page)
    let following = Task { await support.follow() }
    defer { following.cancel() }
    await until { support.storefront == "USA" }
    try #require(support.shownPage != nil)

    for isAdmin in [false, true] {
      #expect(
        !SettingsSection.shown(isAdmin: isAdmin, hasParents: true, support: support.shownPage).contains(
          .supportWishbone))
    }
    #expect(
      SettingsSection.shown(isAdmin: false, hasParents: false, support: support.shownPage).contains(.supportWishbone))
  }

  @Test("A build with no support address has no row, even on the US storefront")
  func noAddress() async throws {
    // The app's Info.plist takes the address from `WISHBONE_SUPPORT_URL` in `Config/Shared.xcconfig`.
    let setting = try #require(Bundle.main.object(forInfoDictionaryKey: "WishboneSupportURL") as? String)
    #expect(AppAbout.current.support == URL(string: setting))
    #expect(AppAbout.current.support?.scheme == "https")
    // An empty value, or one that is not a web address, is no address.
    #expect(AppAbout(info: [:]).support == nil)
    #expect(AppAbout(info: ["WishboneSupportURL": ""]).support == nil)
    #expect(AppAbout(info: ["WishboneSupportURL": "file:///etc/hosts"]).support == nil)

    let support = SupportWishbone(source: FakeStorefront(current: "USA"), address: AppAbout(info: [:]).support)
    let following = Task { await support.follow() }
    defer { following.cancel() }
    await until { support.storefront == "USA" }
    #expect(support.shownPage == nil)
    #expect(
      !SettingsSection.shown(isAdmin: false, hasParents: false, support: support.shownPage).contains(.supportWishbone))

    var opened: [URL] = []
    support.tap { opened.append($0) }
    #expect(opened.isEmpty)
  }

  @Test("A tap opens the address, once, with no screen in between")
  func tap() async {
    let support = SupportWishbone(source: FakeStorefront(current: "USA"), address: Self.page)
    let following = Task { await support.follow() }
    defer { following.cancel() }
    await until { support.storefront == "USA" }

    // The tap hands the address straight to the system's open: nothing is shown first.
    var opened: [URL] = []
    support.tap { opened.append($0) }
    #expect(opened == [Self.page])
  }
}

/// A storefront that the test sets, in StoreKit's shape: a country code, or `nil` while it is unknown.
@MainActor
final class FakeStorefront: StorefrontSource {
  nonisolated let initial: String?
  private let stream: AsyncStream<String>
  private let continuation: AsyncStream<String>.Continuation

  /// Whether `updates()` has been asked for: the model reads the current storefront first, then follows.
  private(set) var isFollowed = false

  init(current: String?) {
    initial = current
    (stream, continuation) = AsyncStream.makeStream()
  }

  nonisolated func current() async -> String? { initial }

  nonisolated func updates() -> AsyncStream<String> {
    MainActor.assumeIsolated {
      isFollowed = true
      return stream
    }
  }

  /// A new storefront, as StoreKit sends it.
  func change(to code: String) {
    continuation.yield(code)
  }
}
