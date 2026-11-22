import Foundation
import SwiftUI
import WishboneAPI
import WishboneSession

/// One of the places that every window has: the three tabs, and the Add screen that the plus opens. See "Tabs
/// that become a sidebar" in `docs/spec.md`.
public enum WindowTab: String, Codable, Sendable, CaseIterable {
  case home
  case lists
  case gifts

  /// The Add screen. It is a place, not a sheet.
  case add
}

/// A page that a window pushes on a tab. It names its thing by ID only.
public enum Page: Codable, Hashable, Sendable {
  case list(id: String)
  case user(id: String)

  /// An item's page. Its address has no list, so the page stays when the item moves.
  case item(id: String)
  case people

  /// The tab that owns the page, for a sidebar shortcut: one of your lists is in Lists, and People, a user, or an
  /// item is on Home.
  public var owner: WindowTab {
    switch self {
    case .list: .lists
    case .user, .item, .people: .home
    }
  }
}

/// A window's place: its tab, and the pages pushed on each tab. Every window has its own. See
/// `docs/screens/tabs-and-sidebar.md`, and "What a window remembers" in `docs/spec.md`.
public struct WindowPlace: Equatable, Sendable {
  /// The tab that the window shows.
  public private(set) var tab = WindowTab.home

  /// The pages pushed on each tab that has any.
  private var pushed: [WindowTab: [Page]] = [:]

  /// The place of a new window: Home, with nothing pushed.
  public init() {}

  /// The pages pushed on the tab, from the first one pushed. The tab's navigation stack reads and writes them, so
  /// a push adds a page, and Back removes the last one.
  public subscript(pagesOn tab: WindowTab) -> [Page] {
    get { pushed[tab] ?? [] }
    set { pushed[tab] = newValue.isEmpty ? nil : newValue }
  }

  /// A tap on a tab. To change the tab keeps the pages of each tab. A tap on the selected tab pops to its first
  /// screen.
  public mutating func select(_ tab: WindowTab) {
    if tab == self.tab {
      self[pagesOn: tab] = []
    } else {
      self.tab = tab
    }
  }

  /// A sidebar shortcut: it selects the tab that owns the page, and the page replaces whatever was pushed on
  /// that tab. Back goes to the tab's first screen.
  public mutating func open(_ page: Page) {
    tab = page.owner
    self[pagesOn: tab] = [page]
  }
}

// MARK: - What a window remembers

extension WindowPlace {
  /// The place as a window saves it for its scene: the tab and the pages, by ID only, and the name of the session
  /// that they belong to.
  private struct Saved: Codable {
    var session: String
    var tab: WindowTab
    var pages: [String: [Page]]
  }

  /// What the window saves, for the session.
  public func saved(for session: Session) -> Data {
    var pages: [String: [Page]] = [:]
    for (tab, pushed) in pushed { pages[tab.rawValue] = pushed }
    // A place is a few short strings, which always encode.
    return (try? JSONEncoder().encode(Saved(session: session.opaqueName, tab: tab, pages: pages))) ?? Data()
  }

  /// The place of a restored window.
  ///
  /// - A page whose thing is not in the copy any more is dropped quietly. The window shows what was under it.
  ///   `isInCopy` says whether a page's thing is in the copy.
  /// - What another session saved is not restored: the window starts at Home. So does a window with nothing
  ///   saved, or with something that can't be read.
  public init(restoring saved: Data?, for session: Session, where isInCopy: (Page) -> Bool) {
    guard let saved, let saved = try? JSONDecoder().decode(Saved.self, from: saved),
      saved.session == session.opaqueName
    else { return }
    tab = saved.tab
    for tab in WindowTab.allCases {
      self[pagesOn: tab] = (saved.pages[tab.rawValue] ?? []).filter(isInCopy)
    }
  }
}

extension Page {
  /// What a page shows.
  public enum Content: Equatable, Sendable {
    /// A list's page. The page reads what it shows from the session model: see `SessionModel.listPage(id:)`.
    case list(id: String)

    /// A user's page. The page reads what it shows from the session model: see `SessionModel.userPage(id:today:)`.
    case user(id: String)

    /// An item's page. The page reads what it shows from the session model: see `SessionModel.itemPage(id:)`.
    case item(id: String)
    case people

    /// The "not found" page: the page's thing is not in the copy. A missing thing and a hidden thing are the
    /// same, because the copy holds neither. See `docs/screens/not-found.md`.
    case notFound
  }

  /// What the page shows, from the session's copy.
  public func content(in session: SessionModel) -> Content {
    switch self {
    case .list(let id): session.listPage(id: id) == nil ? .notFound : .list(id: id)
    // A user whom the copy holds only as a summary has no page, on the server or here.
    case .user(let id): session.userPage(id: id) == nil ? .notFound : .user(id: id)
    case .item(let id): session.itemPage(id: id) == nil ? .notFound : .item(id: id)
    case .people: .people
    }
  }
}

// MARK: - The place opened, for diagnostics

extension WindowTab {
  /// The tab's kind of place, for a breadcrumb.
  var placeKind: PlaceKind {
    switch self {
    case .home: .home
    case .lists: .lists
    case .gifts: .gifts
    case .add: .add
    }
  }
}

extension Page {
  /// The page's kind of place, for a breadcrumb: never what it shows.
  var placeKind: PlaceKind {
    switch self {
    case .list: .listPage
    case .user: .userPage
    case .item: .itemPage
    case .people: .people
    }
  }
}

extension WindowPlace {
  /// The kind of the place that the window shows: the last page pushed on its tab, or the tab.
  public var shownKind: PlaceKind {
    self[pagesOn: tab].last?.placeKind ?? tab.placeKind
  }

  /// The place that the window opened since `earlier`, by its kind: a new tab, a page pushed, or the page under one
  /// that went back. Nil when the window shows the same place.
  public func opened(since earlier: WindowPlace) -> PlaceKind? {
    guard tab != earlier.tab || self[pagesOn: tab] != earlier[pagesOn: tab] else { return nil }
    return shownKind
  }
}

extension EnvironmentValues {
  /// Where the window's breadcrumbs go. Only the app gives one: the share extension sends nothing.
  @Entry public var diagnosticsReporter: any DiagnosticsReporter = NoDiagnostics()
}
