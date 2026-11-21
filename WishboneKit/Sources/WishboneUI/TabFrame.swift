import SwiftUI
import WishboneSession

/// The frame around every screen behind the sign-in: Home, Lists, Gifts, and the plus. In a narrow window it is a
/// tab bar. In a wide window it is a sidebar, with shortcuts to the user's lists and to People. See
/// `docs/screens/tabs-and-sidebar.md` and ADR 0001.
///
/// The frame shows the window's place, and changes it. The window owns the place, and saves it.
public struct TabFrame: View {
  private let session: SessionModel
  @Binding private var place: WindowPlace

  /// The text in the Add screen's field. Each window has its own.
  @State private var search = ""

  public init(session: SessionModel, place: Binding<WindowPlace>) {
    self.session = session
    _place = place
  }

  /// A tap on a tab selects it. A tap on the selected tab pops to its first screen.
  private var tab: Binding<WindowTab> {
    Binding {
      place.tab
    } set: { tab in
      place.select(tab)
    }
  }

  public var body: some View {
    TabView(selection: tab) {
      Tab(value: WindowTab.home) {
        stack(on: .home) { HomeStandInScreen(session: session) }
      } label: {
        Label {
          Text("Home", bundle: #bundle)
        } icon: {
          Image(systemName: "house")
        }
      }

      Tab(value: WindowTab.lists) {
        stack(on: .lists) { ListsStandInScreen() }
      } label: {
        Label {
          Text("Lists", bundle: #bundle)
        } icon: {
          Image(systemName: "list.bullet")
        }
      }

      Tab(value: WindowTab.gifts) {
        stack(on: .gifts) { GiftsStandInScreen() }
      } label: {
        Label {
          Text("Gifts", bundle: #bundle)
        } icon: {
          Image(systemName: "gift")
        }
      }

      // The plus: the round button that the system sets apart at the end of the tab bar.
      Tab(value: WindowTab.add, role: .search) {
        stack(on: .add) { AddScreen(search: $search) }
      } label: {
        Label {
          Text("Add", bundle: #bundle)
        } icon: {
          Image(systemName: "plus")
        }
      }
    }
    .tabViewStyle(.sidebarAdaptable)
    // The plus opens the Add screen with its field ready.
    .tabViewSearchActivation(.searchTabSelection)
    .tabViewSidebarFooter { shortcuts }
  }

  /// The sidebar's shortcuts: your lists, then People. They are rows under the tabs, in the sidebar only, so a
  /// tab bar never shows them.
  private var shortcuts: some View {
    VStack(alignment: .leading, spacing: 0) {
      if !session.yourLists.isEmpty {
        SidebarHeading(words: String(localized: "Your lists", bundle: #bundle))
        ForEach(session.yourLists) { list in
          SidebarShortcut(name: list.name, systemImage: "list.bullet") { place.open(.list(id: list.id)) }
        }
      }
      SidebarShortcut(name: String(localized: "People", bundle: #bundle), systemImage: "person.2") {
        place.open(.people)
      }
    }
  }

  /// A tab's navigation stack: the tab's first screen, with the window's pages for the tab pushed on it.
  private func stack(on tab: WindowTab, @ViewBuilder first: () -> some View) -> some View {
    NavigationStack(path: $place[pagesOn: tab]) {
      first()
        .navigationDestination(for: Page.self) { page in
          PageScreen(page: page, session: session)
        }
    }
  }
}
