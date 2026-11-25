import Observation
import SwiftUI
import Testing
import UIKit
import WishboneAPI
import WishboneSession
import WishboneUI

/// The states that every screen behind the tabs shares, in a window of the app: the line "Can't reach {address}",
/// Loading, Can't reach, and Empty. See "What every screen shares" in `docs/screens/README.md`, and "Can't reach" in
/// `docs/screens/tabs-and-sidebar.md`.
///
/// SwiftUI draws text with no UIKit view, and the test process builds no accessibility tree. So these tests read
/// what UIKit shows: the room that the line takes above a list, and the progress indicator. The sign-in journey
/// reads the words in the tabs, and taps Try again.
@Suite("The shared states", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct SharedStatesTests {
  static let tabs: [(WindowTab, String)] = [(.home, "Home"), (.lists, "Lists"), (.gifts, "Gifts")]

  @Test("The line shows above saved rows, with the address, while the state says so, and wraps at the largest size")
  func line() async throws {
    let address = try #require(InstanceAddress("http://wishbone.example-family.ts.net:8080"))
    #expect(CantReach.words(for: address) == "Can't reach http://wishbone.example-family.ts.net:8080")
    let window = try LineWindow(address: address)

    // With no line, the list starts under the window's safe area.
    await until { window.listTopInset != nil }
    let without = try #require(window.listTopInset)

    // The line is a row pinned above the list: the list starts lower by its height.
    window.owner.state = .saved(cantReach: true)
    await until { (window.listTopInset ?? 0) > without + 10 }
    let line = try #require(window.listTopInset) - without

    // At the largest text size, the line wraps, and the address is never cut short: it takes more lines.
    window.textSize = .accessibilityExtraExtraExtraLarge
    await until { (window.listTopInset ?? 0) - without > line * 2 }

    // A sync that reaches the instance takes the line away.
    window.owner.state = .saved(cantReach: false)
    await until { window.listTopInset == without }
  }

  @Test("A screen with no rows shows the progress indicator, the unreachable view, or its empty view, by its state")
  func noRows() async throws {
    let instance = try await StandInInstance.start()
    let device = try signedInDevice(on: instance)
    let session = try #require(device.session)
    let window = try FrameWindow(session: session)

    var loading: [WindowTab: CGFloat] = [:]
    for (tab, title) in Self.tabs {
      if window.place.tab != tab { window.place.select(tab) }
      await until { window.tabs?.selectedTab?.title == title && window.listTopInset != nil }
      // No sync has run yet: Loading, with the system's progress indicator.
      #expect(session.screenState(hasRows: false) == .loading)
      await until { window.showsProgress }
      loading[tab] = window.listTopInset
    }

    // The instance can't be reached, and nothing is saved: the unreachable view, never empty, and no line above it.
    instance.isAway = true
    #expect(await session.syncNow() == .unreachable)
    #expect(session.screenState(hasRows: false) == .cantReach)
    for (tab, title) in Self.tabs {
      if window.place.tab != tab { window.place.select(tab) }
      await until { window.tabs?.selectedTab?.title == title && !window.showsProgress }
      #expect(window.listTopInset == loading[tab], "\(title): a line shows above the unreachable view")
    }

    // Try again is Sync now. A sync that succeeds and finds nothing gives each screen its empty view.
    instance.isAway = false
    let before = instance.pullCount
    #expect(await session.syncNow() == .succeeded)
    #expect(instance.pullCount == before + 1)
    #expect(session.screenState(hasRows: false) == .empty)
    for (tab, title) in Self.tabs {
      if window.place.tab != tab { window.place.select(tab) }
      await until { window.tabs?.selectedTab?.title == title }
      #expect(!window.showsProgress, "\(title)")
    }
  }

  @Test("After a refused first sync, a screen with no rows shows the error view, never the progress indicator")
  func refusedFirstSync() async throws {
    let instance = try await StandInInstance.start()
    let device = try signedInDevice(on: instance)
    let session = try #require(device.session)
    let window = try FrameWindow(session: session)
    await until { window.tabs?.selectedTab?.title == "Home" && window.showsProgress }

    // The instance refuses the versions: the error view, with no progress indicator and no line above it.
    instance.isRefusing = true
    #expect(await session.syncNow() == .stopped)
    #expect(session.screenState(hasRows: false) == .firstSyncFailed)
    for (tab, title) in Self.tabs {
      if window.place.tab != tab { window.place.select(tab) }
      await until { window.tabs?.selectedTab?.title == title && !window.showsProgress }
    }

    // Try again, once the instance answers, gives each screen its empty view.
    instance.isRefusing = false
    #expect(await session.tryAgain() == .succeeded)
    #expect(session.screenState(hasRows: false) == .empty)
    for (tab, title) in Self.tabs {
      if window.place.tab != tab { window.place.select(tab) }
      await until { window.tabs?.selectedTab?.title == title && !window.showsProgress }
    }
  }
}

/// A window that shows a list under the shared states, at a state that the test owns, with no navigation bar.
@MainActor
private final class LineWindow {
  @Observable
  @MainActor
  final class Owner {
    var state = ScreenState.saved(cantReach: false)
  }

  struct Root: View {
    let owner: Owner
    let address: InstanceAddress

    var body: some View {
      List {
        Text("Kite")
      }
      .sharedStates(owner.state, address: address, tryAgain: {}) { EmptyView() }
    }
  }

  let owner = Owner()
  private let window: UIWindow
  private let root: UIHostingController<Root>

  init(address: InstanceAddress) throws {
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    window = UIWindow(windowScene: scene)
    root = UIHostingController(rootView: Root(owner: owner, address: address))
    window.rootViewController = root
    window.makeKeyAndVisible()
  }

  deinit {
    let window = window
    Task { @MainActor in window.isHidden = true }
  }

  /// The text size of the window.
  var textSize: UIContentSizeCategory {
    get { root.traitOverrides.preferredContentSizeCategory }
    set { root.traitOverrides.preferredContentSizeCategory = newValue }
  }

  /// Where the list starts: the window's safe area, and the line when it shows.
  var listTopInset: CGFloat? {
    Self.first(UICollectionView.self, in: root.view).map(\.adjustedContentInset.top)
  }

  private static func first<View: UIView>(_ type: View.Type, in view: UIView) -> View? {
    if let view = view as? View { return view }
    return view.subviews.lazy.compactMap { first(type, in: $0) }.first
  }
}
