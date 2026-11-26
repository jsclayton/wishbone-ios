import TestSupport
import XCTest

/// The journey of a person who puts their list in a new order, against a real test server. From the Lists tab, their
/// own list's page, where the toolbar's Edit button shows the handles. A drag of the last item's handle to the top
/// puts it first at once, and the server has the same order. Done ends the edit mode. With the list sorted by price,
/// the Edit button is gone. See "Every drag has a way without dragging" and "Where an item can land" in
/// `docs/spec.md`, and Reorder in `docs/screens/list.md`.
///
/// It audits the page in edit mode, and attaches a screenshot of it as evidence for a person.
nonisolated final class ReorderJourney: JourneyTestCase {
  @MainActor
  func testReorder() async {
    continueAfterFailure = false
    // XCTest reports an error that a test throws at the place of the last error thrown anywhere, even one that
    // was caught. So the journey catches its own error, and fails with it here.
    do {
      try await reorder()
    } catch {
      XCTFail("\(error)")
    }
  }

  @MainActor
  private func reorder() async throws {
    let server = try await TestServer.shared()
    let builder = try await FixtureBuilder(server: server)
    let farOff = FixtureBuilder.monthAndDay(daysFromNow: Audit.farOff)
    let robin = try await builder.person("Robin", birthday: farOff)
    // A user who confirmed their profile, so the app shows them no profile gate.
    try await builder.confirmProfile(of: robin)
    let list = try await builder.list("Toys", of: robin)
    var items: [Fixture.Item] = []
    for title in ["Ball", "Bat", "Cap"] {
      items.append(try await builder.item(builder.name(title), on: list, as: robin))
    }
    let (ball, bat, cap) = (items[0], items[1], items[2])

    let app = Audit.app()
    app.launchEnvironment["WISHBONE_JOURNEY_START_SIGNED_OUT"] = "1"
    app.launchEnvironment["WISHBONE_JOURNEY_LOGIN_LINK"] = try await builder.loginLink(for: robin).absoluteString
    app.launch()
    let lists = app.tabBars.firstMatch.buttons[Audit.words("Lists")]
    XCTAssertTrue(lists.waitForExistence(timeout: 60), "The tabs didn't show after the sign-in.")

    // The Lists tab, then the list's page with its items in the list's order.
    lists.tap()
    // A list's row reads words made from a format, which the double-length pseudo-language puts after its places.
    let listRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", list.name)).firstMatch
    XCTAssertTrue(listRow.waitForExistence(timeout: 30), "The Lists tab has no row for the list.")
    listRow.tap()
    let row = { (item: Fixture.Item) in
      app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", item.title)).firstMatch
    }
    XCTAssertTrue(row(cap).waitForExistence(timeout: 30), "The list's page has no row for the last item.")

    // Edit is the system's own button, in the system's words, which the double-length pseudo-language may double.
    let bar = app.navigationBars.firstMatch
    let edit = bar.buttons.matching(NSPredicate(format: "label IN %@", ["Edit", "Edit Edit"])).firstMatch
    XCTAssertTrue(edit.waitForExistence(timeout: 10), "The list's page has no Edit button in List order.")
    edit.tap()
    let done = bar.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Done Done"])).firstMatch
    XCTAssertTrue(done.waitForExistence(timeout: 10), "Edit didn't start the edit mode.")

    // The handles: one for each item. The system names each for its row.
    let handles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder'"))
    XCTAssertTrue(handles.firstMatch.waitForExistence(timeout: 10), "The edit mode shows no handles.")
    try await Audit.run(on: app, showing: "a list's page in edit mode", in: self)

    // The last item's handle, dragged to the first item's place, puts it first.
    let capHandle = handles.matching(NSPredicate(format: "label CONTAINS %@", cap.title)).firstMatch
    let ballHandle = handles.matching(NSPredicate(format: "label CONTAINS %@", ball.title)).firstMatch
    XCTAssertTrue(capHandle.exists && ballHandle.exists, "The handles don't name their rows.")
    capHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
      forDuration: 0.6, thenDragTo: ballHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)),
      withVelocity: .slow, thenHoldForDuration: 0.6)
    var isFirst = false
    for _ in 0..<20 where !isFirst {
      isFirst = row(cap).frame.minY < row(ball).frame.minY
      if !isFirst { try await Task.sleep(for: .milliseconds(500)) }
    }
    XCTAssertTrue(isFirst, "The dragged item isn't first on the page.")

    // The server has the same order.
    let order = try await order(on: list.id, as: robin, until: [cap.title, ball.title, bat.title])
    XCTAssertEqual(order, [cap.title, ball.title, bat.title], "The server's order isn't the page's.")

    // Done ends the edit mode.
    done.tap()
    XCTAssertTrue(edit.waitForExistence(timeout: 10), "Done didn't end the edit mode.")

    // Sorted by price, the list takes no reorder: Edit is gone.
    let more = bar.buttons[Audit.words("More")].firstMatch
    XCTAssertTrue(more.waitForExistence(timeout: 10), "The list's page has no menu.")
    more.tap()
    let sort = app.buttons[Audit.words("Sort")].firstMatch
    XCTAssertTrue(sort.waitForExistence(timeout: 10), "The menu has no Sort.")
    sort.tap()
    let price = app.buttons[Audit.words("Price")].firstMatch
    XCTAssertTrue(price.waitForExistence(timeout: 10), "Sort has no Price.")
    price.tap()
    XCTAssertTrue(edit.waitForNonExistence(timeout: 10), "Edit shows on a list sorted by price.")
    app.terminate()
  }

  /// The titles of the list's items, in the list's order, as the server has them. The app sends the reorder behind
  /// the drag, so this asks until the server has the order given, and gives up after a long time.
  @MainActor
  private func order(on list: String, as person: Fixture.Person, until expected: [String]) async throws -> [String] {
    let session = try person.signedIn()
    var titles: [String] = []
    for _ in 0..<60 {
      titles = try await session.all("/lists/\(list)/items").compactMap { $0["title"].string }
      if titles == expected { return titles }
      try await Task.sleep(for: .milliseconds(500))
    }
    return titles
  }
}
