import TestSupport
import XCTest

/// The journey of a person who chooses from a list page's menu while the app syncs, against a real test server. The
/// app syncs every few seconds here, in place of every 60 (`WISHBONE_JOURNEY_TIMER_SECONDS`). With More open and Sort
/// open in it, syncs with no change to the list, and then a sync that brings a new item, leave Sort open. Price then
/// sorts by price, and the new item is on the page. See "When the app syncs" in `docs/spec.md`, and Actions in
/// `docs/screens/list.md`.
nonisolated final class MenuAcrossSyncJourney: JourneyTestCase {
  /// How often the app syncs in this journey, in seconds.
  private static let timerSeconds = 4

  /// How long the journey waits for the timer's first sync to show on the page, in seconds: several of the timer's
  /// intervals, with room for a slow simulator.
  private static let firstTimerSync: TimeInterval = 30

  @MainActor
  func testMenuStaysOpenAcrossASync() async {
    continueAfterFailure = false
    // XCTest reports an error that a test throws at the place of the last error thrown anywhere, even one that
    // was caught. So the journey catches its own error, and fails with it here.
    do {
      try await chooseAcrossASync()
    } catch {
      XCTFail("\(error)")
    }
  }

  @MainActor
  private func chooseAcrossASync() async throws {
    let server = try await TestServer.shared()
    let builder = try await FixtureBuilder(server: server)
    let farOff = FixtureBuilder.monthAndDay(daysFromNow: Audit.farOff)
    let sam = try await builder.person("Sam", birthday: farOff)
    // A user who confirmed their profile, so the app shows them no profile gate.
    try await builder.confirmProfile(of: sam)
    let list = try await builder.list("Books", of: sam)
    let first = try await builder.item(builder.name("Atlas"), on: list, as: sam)

    let app = Audit.app()
    app.launchEnvironment["WISHBONE_JOURNEY_START_SIGNED_OUT"] = "1"
    app.launchEnvironment["WISHBONE_JOURNEY_LOGIN_LINK"] = try await builder.loginLink(for: sam).absoluteString
    app.launchEnvironment["WISHBONE_JOURNEY_TIMER_SECONDS"] = String(Self.timerSeconds)
    app.launch()
    let lists = app.tabBars.firstMatch.buttons[Audit.words("Lists")]
    XCTAssertTrue(lists.waitForExistence(timeout: 60), "The tabs didn't show after the sign-in.")

    // The Lists tab, then the list's page.
    lists.tap()
    // A list's row reads words made from a format, which the double-length pseudo-language puts after its places.
    let listRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", list.name)).firstMatch
    XCTAssertTrue(listRow.waitForExistence(timeout: 30), "The Lists tab has no row for the list.")
    listRow.tap()
    let row = { (title: String) in
      app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }
    XCTAssertTrue(row(first.title).waitForExistence(timeout: 30), "The list's page has no row for its item.")

    // The timer syncs: an item added on the server shows on the page with nothing touched. Only then is Sort opened,
    // so that syncs come while it is open. The timer doesn't wait for the rebuild of the reminders after the sign-in,
    // whose first ask for authorization iOS took 78 seconds to answer on a simulator.
    let early = try await builder.item(builder.name("Almanac"), on: list, as: sam)
    XCTAssertTrue(
      row(early.title).waitForExistence(timeout: Self.firstTimerSync),
      "The timer didn't sync within \(Int(Self.firstTimerSync)) seconds.")

    // Edit is the system's own button, in the system's words, which the double-length pseudo-language may double. It
    // shows in List order, and goes in Price order.
    let bar = app.navigationBars.firstMatch
    let edit = bar.buttons.matching(NSPredicate(format: "label IN %@", ["Edit", "Edit Edit"])).firstMatch
    XCTAssertTrue(edit.waitForExistence(timeout: 10), "The list's page has no Edit button in List order.")

    // More, then Sort in it.
    let more = bar.buttons[Audit.words("More")].firstMatch
    XCTAssertTrue(more.waitForExistence(timeout: 10), "The list's page has no menu.")
    more.tap()
    let sort = app.buttons[Audit.words("Sort")].firstMatch
    XCTAssertTrue(sort.waitForExistence(timeout: 10), "The menu has no Sort.")
    sort.tap()
    let price = app.buttons[Audit.words("Price")].firstMatch
    XCTAssertTrue(price.waitForExistence(timeout: 10), "Sort has no Price.")

    // Syncs with no change to the list: Sort stays open.
    try await holdOpen(price, for: .seconds(Self.timerSeconds * 3), while: "the app synced with no change")

    // A new item on the server, which the next sync brings: Sort stays open.
    let added = try await builder.item(builder.name("Bestiary"), on: list, as: sam)
    try await holdOpen(price, for: .seconds(Self.timerSeconds * 3), while: "the app synced a new item")

    // Price sorts by price, so Edit goes, and the new item is on the page: a sync brought it while Sort was open.
    price.tap()
    XCTAssertTrue(edit.waitForNonExistence(timeout: 10), "Price didn't sort the list by price.")
    XCTAssertTrue(row(added.title).waitForExistence(timeout: 10), "No sync brought the new item while Sort was open.")
    app.terminate()
  }

  /// Checks once a second, for the time, that Price still shows in Sort. It throws at the first check that has none.
  @MainActor
  private func holdOpen(_ price: XCUIElement, for time: Duration, while what: String) async throws {
    let end = ContinuousClock.now + time
    while ContinuousClock.now < end {
      guard price.exists else {
        let shown = "Sort closed while \(what)"
        if let taken = try? await Screenshot.take(of: XCUIApplication(), showing: shown) {
          let attachment = XCTAttachment(screenshot: taken.screenshot)
          attachment.name = shown
          attachment.lifetime = .keepAlways
          add(attachment)
        }
        throw AuditError("\(shown): Price no longer shows.")
      }
      try await Task.sleep(for: .seconds(1))
    }
  }
}
