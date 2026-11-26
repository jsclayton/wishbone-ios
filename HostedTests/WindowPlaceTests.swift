import Foundation
import Testing
import WishboneAPI
import WishboneUI

/// A window's place: its tab, and the pages pushed on each tab. See "Tabs that become a sidebar" and "What a
/// window remembers" in `docs/spec.md`, and `docs/screens/tabs-and-sidebar.md`.
@Suite("A window's place", .timeLimit(.minutes(1)))
struct WindowPlaceTests {
  /// The session of the window, and another user's session on the same instance.
  let session: Session
  let other: Session

  init() throws {
    let instance = try #require(InstanceAddress("http://10.0.0.5:8080/family"))
    session = Session(instance: instance, token: "a-token-for-the-test", userID: "7")
    other = Session(instance: instance, token: "another-token", userID: "8")
  }

  @Test("A new window opens on Home. A change of tab keeps the pages of each tab")
  func tabsKeepTheirPages() {
    var place = WindowPlace()
    #expect(place.tab == .home)
    #expect(WindowTab.allCases.allSatisfy { place[pagesOn: $0].isEmpty })

    place[pagesOn: .home] = [.people, .user(id: "8")]
    place.select(.lists)
    place[pagesOn: .lists] = [.list(id: "3")]
    place.select(.gifts)
    #expect(place.tab == .gifts)
    #expect(place[pagesOn: .home] == [.people, .user(id: "8")])
    #expect(place[pagesOn: .lists] == [.list(id: "3")])

    place.select(.home)
    #expect(place.tab == .home)
    #expect(place[pagesOn: .home] == [.people, .user(id: "8")])
  }

  @Test("A shortcut selects the tab that owns the page, and replaces what was pushed there")
  func shortcuts() {
    var place = WindowPlace()
    place.select(.lists)
    place[pagesOn: .lists] = [.list(id: "3"), .list(id: "4")]
    place.select(.gifts)

    // One of your lists is in Lists.
    place.open(.list(id: "5"))
    #expect(place.tab == .lists)
    #expect(place[pagesOn: .lists] == [.list(id: "5")])

    // People and a user are on Home. Lists keeps its page.
    place[pagesOn: .home] = [.user(id: "8")]
    place.open(.people)
    #expect(place.tab == .home)
    #expect(place[pagesOn: .home] == [.people])
    place.open(.user(id: "9"))
    #expect(place.tab == .home)
    #expect(place[pagesOn: .home] == [.user(id: "9")])
    #expect(place[pagesOn: .lists] == [.list(id: "5")])

    // Back, as the navigation bar's button does it: the tab's first screen is under the page.
    place[pagesOn: .home].removeLast()
    #expect(place.tab == .home)
    #expect(place[pagesOn: .home].isEmpty)
  }

  @Test("The server's ID takes the place of a stand-in in the pages of every tab, and opens no new place")
  func standInsReplaced() {
    var place = WindowPlace()
    place[pagesOn: .home] = [.item(id: "stand-in-1")]
    place.select(.lists)
    place[pagesOn: .lists] = [.list(id: "3"), .item(id: "stand-in-1"), .item(id: "stand-in-2")]
    let earlier = place

    place.replaceStandIns(["stand-in-1": "41"])

    #expect(place[pagesOn: .home] == [.item(id: "41")])
    #expect(place[pagesOn: .lists] == [.list(id: "3"), .item(id: "41"), .item(id: "stand-in-2")])
    #expect(place.tab == .lists)
    #expect(place == earlier.replacingStandIns(["stand-in-1": "41"]))
    #expect(place.opened(since: earlier.replacingStandIns(["stand-in-1": "41"])) == nil)
    // A stand-in that no ID replaced stays, and no map changes nothing.
    var same = place
    same.replaceStandIns([:])
    #expect(same == place)
  }

  @Test(
    "A list's page pushed by its stand-in, after New list, shows by the server's ID on every tab, as an item's does")
  func listStandInsReplaced() {
    var place = WindowPlace()
    place.select(.lists)
    place[pagesOn: .lists] = [.list(id: "stand-in-list"), .item(id: "stand-in-item"), .list(id: "3")]
    place[pagesOn: .home] = [.list(id: "stand-in-list")]
    let earlier = place

    place.replaceStandIns(["stand-in-list": "41", "stand-in-item": "52"])

    #expect(place[pagesOn: .lists] == [.list(id: "41"), .item(id: "52"), .list(id: "3")])
    #expect(place[pagesOn: .home] == [.list(id: "41")])
    #expect(place.opened(since: earlier.replacingStandIns(["stand-in-list": "41", "stand-in-item": "52"])) == nil)
  }

  @Test("A tap on the selected tab pops to its first screen")
  func tapOnTheSelectedTab() {
    var place = WindowPlace()
    place[pagesOn: .home] = [.people, .user(id: "8")]
    place.select(.lists)
    place[pagesOn: .lists] = [.list(id: "3")]

    place.select(.lists)
    #expect(place.tab == .lists)
    #expect(place[pagesOn: .lists].isEmpty)
    // The other tabs keep their pages.
    #expect(place[pagesOn: .home] == [.people, .user(id: "8")])
  }

  @Test("A restored window has its tab and its pages, by ID")
  func restore() throws {
    var place = WindowPlace()
    place[pagesOn: .home] = [.people, .user(id: "8")]
    place.select(.lists)
    place[pagesOn: .lists] = [.list(id: "3")]
    let saved = place.saved(for: session)

    let restored = WindowPlace(restoring: saved, for: session) { _ in true }
    #expect(restored == place)
    #expect(restored.tab == .lists)
    #expect(restored[pagesOn: .home] == [.people, .user(id: "8")])
    #expect(restored[pagesOn: .lists] == [.list(id: "3")])

    // What is saved holds IDs only, and names its session without the instance address, the user, or the token.
    let text = try #require(String(data: saved, encoding: .utf8))
    #expect(!text.contains("10.0.0.5"))
    #expect(!text.contains("a-token-for-the-test"))
    #expect(!text.contains("\"7\""))

    // A window with nothing saved, or with something that it can't read, opens on Home.
    #expect(WindowPlace(restoring: nil, for: session) { _ in true } == WindowPlace())
    #expect(WindowPlace(restoring: Data("not a place".utf8), for: session) { _ in true } == WindowPlace())
  }

  @Test("On restore, a page whose thing is gone is dropped, and the window shows what was under it")
  func restoreDropsWhatIsGone() {
    var place = WindowPlace()
    place[pagesOn: .home] = [.people, .user(id: "8"), .list(id: "3")]
    place.select(.lists)
    place[pagesOn: .lists] = [.list(id: "4")]
    let saved = place.saved(for: session)

    // The list on top of Home is gone: the user's page was under it.
    let withoutTheList = WindowPlace(restoring: saved, for: session) { $0 != .list(id: "3") }
    #expect(withoutTheList.tab == .lists)
    #expect(withoutTheList[pagesOn: .home] == [.people, .user(id: "8")])
    #expect(withoutTheList[pagesOn: .lists] == [.list(id: "4")])

    // The user is gone: the list stays, on top of People. The only page on Lists is gone: Lists is under it.
    let withoutTheUser = WindowPlace(restoring: saved, for: session) { $0 != .user(id: "8") && $0 != .list(id: "4") }
    #expect(withoutTheUser.tab == .lists)
    #expect(withoutTheUser[pagesOn: .home] == [.people, .list(id: "3")])
    #expect(withoutTheUser[pagesOn: .lists].isEmpty)
  }

  @Test("After a change of session, every window starts at Home")
  func changeOfSession() {
    var place = WindowPlace()
    place[pagesOn: .home] = [.people]
    place.select(.gifts)
    let saved = place.saved(for: session)

    #expect(WindowPlace(restoring: saved, for: other) { _ in true } == WindowPlace())
    #expect(WindowPlace(restoring: saved, for: session) { _ in true } == place)
  }

  @Test("Each place that a window opens is named by its kind, never by what it shows")
  func openedKind() {
    var place = WindowPlace()
    let start = place
    #expect(place.opened(since: start) == nil)

    place.select(.lists)
    #expect(place.opened(since: start) == .lists)
    var earlier = place
    place[pagesOn: .lists] = [.list(id: "list-of-robin")]
    #expect(place.opened(since: earlier) == .listPage)
    earlier = place
    place.open(.people)
    #expect(place.opened(since: earlier) == .people)
    earlier = place
    place[pagesOn: .home] = [.people, .user(id: "robin")]
    #expect(place.opened(since: earlier) == .userPage)
    // Back shows the page under it.
    earlier = place
    place[pagesOn: .home] = [.people]
    #expect(place.opened(since: earlier) == .people)
    earlier = place
    place.select(.add)
    #expect(place.opened(since: earlier) == .add)
  }
}
