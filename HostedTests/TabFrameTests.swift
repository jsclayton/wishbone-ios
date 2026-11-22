import Observation
import SwiftUI
import Testing
import UIKit
import WishboneAPI
import WishboneSession
import WishboneUI

/// The tab frame, in a window of the app: what the frame shows for the window's place. See
/// `docs/screens/tabs-and-sidebar.md` and `docs/screens/not-found.md`.
///
/// The session's copy is empty, because the bundle has no test server: nothing that a page names is in it.
@Suite("The tab frame", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct TabFrameTests {
  let device: Device
  let session: SessionModel

  init() throws {
    let instance = try #require(InstanceAddress("http://127.0.0.1:9"))
    let kept = Session(instance: instance, token: "a-token-for-the-test", userID: "7")
    device = Device(
      Device.Setup(
        userAgent: UserAgent(version: "1.0", isPad: false), keychain: KeptSession(session: kept),
        marker: WrittenMarker(), storage: .memory))
    session = try #require(device.session)
  }

  @Test("A pushed page whose thing is not in the copy shows the \"not found\" page, and Back works")
  func notFound() async throws {
    #expect(Page.list(id: "3").content(in: session) == .notFound)
    #expect(Page.user(id: "8").content(in: session) == .notFound)
    #expect(Page.people.content(in: session) == .people)

    let window = try FrameWindow(session: session)
    window.place.open(.list(id: "3"))

    // The page stays on its tab, on top of the tab's first screen. Nothing goes back by itself.
    await until { window.pagesThatShow == 1 }
    #expect(window.place.tab == .lists)
    #expect(window.place[pagesOn: .lists] == [.list(id: "3")])

    // Back, as the navigation bar's button does it.
    window.goBack()
    await until { window.place[pagesOn: .lists].isEmpty }
    #expect(window.place.tab == .lists)
    #expect(window.pagesThatShow == 0)
  }

  @Test("The plus can be selected by code, and shows the Add screen with its field ready")
  func plus() async throws {
    let window = try FrameWindow(session: session)
    await until { window.tabs?.selectedTab?.title == "Home" }

    window.place.select(.add)

    // The plus is the tab that the system sets apart, in the search role. Its screen has the system search
    // field, and the field is ready: it is the first responder.
    await until { window.tabs?.selectedTab is UISearchTab && window.focusedSearchField != nil }
    #expect(window.tabs?.selectedTab?.title == "Add")
    #expect(window.focusedSearchField?.placeholder == "Paste a link or type what you want")
    #expect(window.place.tab == .add)
  }

  @Test("Pull to refresh on each tab's screen is Sync now, and ends when the sync ends")
  func pullToRefresh() async throws {
    let instance = try await StandInInstance.start()
    let device = try signedInDevice(on: instance)
    let session = try #require(device.session)
    let window = try FrameWindow(session: session)

    let titles: [WindowTab: String] = [.home: "Home", .lists: "Lists", .gifts: "Gifts", .add: "Add"]
    for tab in WindowTab.allCases {
      window.place.select(tab)
      await until { window.tabs?.selectedTab?.title == titles[tab] && window.refresh != nil }
      let before = instance.pullCount
      window.pullToRefresh()
      await until { instance.pullCount == before + 1 }
      await until { window.refresh?.isRefreshing == false }
      #expect(!session.isInstanceUnreachable)
    }
  }
}

/// A device signed in to the stand-in instance, with its copy in memory. Its timer runs on the clock.
@MainActor
func signedInDevice(on instance: StandInInstance, timerClock: ManualClock = ManualClock()) throws -> Device {
  let address = try #require(InstanceAddress(instance.address))
  let kept = Session(instance: address, token: "a-token-for-the-test", userID: "7")
  return Device(
    Device.Setup(
      userAgent: UserAgent(version: "1.0", isPad: false), keychain: KeptSession(session: kept),
      marker: WrittenMarker(), storage: .memory, timerClock: timerClock))
}

/// A session keychain that holds one session, so a device starts signed in.
struct KeptSession: SessionKeychain {
  let session: Session

  func read() throws(SessionKeychainError) -> Session? { session }
  func save(_ session: Session) throws(SessionKeychainError) {}
  func delete() throws(SessionKeychainError) {}
}

/// An install marker that this install has placed, so the kept session is not left over.
struct WrittenMarker: InstallMarker {
  var isPresent: Bool { true }
  func place() {}
}

/// A narrow window of the app that shows the tab frame at a place that the test owns, as a window's root does.
@MainActor
final class FrameWindow {
  @Observable
  @MainActor
  final class Owner {
    var place = WindowPlace()
  }

  struct Root: View {
    @Bindable var owner: Owner
    let session: SessionModel

    var body: some View {
      TabFrame(session: session, place: $owner.place)
    }
  }

  private let owner = Owner()
  private let window: UIWindow

  var place: WindowPlace {
    get { owner.place }
    set { owner.place = newValue }
  }

  init(session: SessionModel) throws {
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    window = UIWindow(windowScene: scene)
    let root = UIHostingController(rootView: Root(owner: owner, session: session))
    // The frame is as a narrow window has it, on any device: a tab bar at the bottom.
    root.traitOverrides.horizontalSizeClass = .compact
    window.rootViewController = root
    window.makeKeyAndVisible()
  }

  deinit {
    let window = window
    Task { @MainActor in window.isHidden = true }
  }

  /// The tab bar controller that the system gives the frame.
  var tabs: UITabBarController? {
    window.rootViewController.flatMap { Self.first(UITabBarController.self, under: $0) }
  }

  /// The top inset of the list on the screen that shows in the selected tab: what the navigation bar, and anything
  /// pinned under it, take from the top of the list. Nil when the screen has no list.
  var listTopInset: CGFloat? {
    guard let view = stack?.topViewController?.view else { return nil }
    return Self.first(UICollectionView.self, in: view).map(\.adjustedContentInset.top)
  }

  /// Whether the screen that shows in the selected tab has the system's progress indicator, turning.
  var showsProgress: Bool {
    guard let view = stack?.topViewController?.view else { return false }
    return Self.first(UIActivityIndicatorView.self, in: view).map { $0.isAnimating && !$0.isHidden } ?? false
  }

  private static func first<View: UIView>(_ type: View.Type, in view: UIView) -> View? {
    if let view = view as? View { return view }
    return view.subviews.lazy.compactMap { first(type, in: $0) }.first
  }

  /// The navigation stack of the selected tab.
  private var stack: UINavigationController? {
    tabs?.selectedViewController.flatMap { Self.first(UINavigationController.self, under: $0) }
  }

  /// The system's pull to refresh on the selected tab's screen. Nil when the screen has none.
  var refresh: UIRefreshControl? {
    tabs?.selectedViewController.flatMap { Self.refreshControl(under: $0.view) }
  }

  /// Pulls to refresh, as a person's pull down on the screen does.
  func pullToRefresh() {
    refresh?.beginRefreshing()
    refresh?.sendActions(for: .valueChanged)
  }

  private static func refreshControl(under view: UIView) -> UIRefreshControl? {
    if let control = (view as? UIScrollView)?.refreshControl { return control }
    return view.subviews.lazy.compactMap { refreshControl(under: $0) }.first
  }

  /// How many pages show on top of the selected tab's first screen.
  var pagesThatShow: Int? {
    stack.map { $0.viewControllers.count - 1 }
  }

  /// Back, as the navigation bar's button does it.
  func goBack() {
    stack?.popViewController(animated: false)
  }

  /// The system search field that has the keyboard, in any window of the scene.
  var focusedSearchField: UISearchTextField? {
    window.windowScene?.windows.lazy.compactMap { Self.focusedSearchField(under: $0) }.first
  }

  private static func first<Controller: UIViewController>(_ type: Controller.Type, under controller: UIViewController)
    -> Controller?
  {
    if let controller = controller as? Controller { return controller }
    return controller.children.lazy.compactMap { first(type, under: $0) }.first
  }

  private static func focusedSearchField(under view: UIView) -> UISearchTextField? {
    if let field = view as? UISearchTextField, field.isFirstResponder { return field }
    return view.subviews.lazy.compactMap { focusedSearchField(under: $0) }.first
  }
}

/// Returns when the window meets the condition. It looks again at each turn, and never decides by a length of
/// time: the suite's time limit ends a wait for something that never comes.
@MainActor
func until(_ condition: @MainActor () -> Bool) async {
  while !condition() {
    try? await Task.sleep(for: .milliseconds(20))
  }
}
