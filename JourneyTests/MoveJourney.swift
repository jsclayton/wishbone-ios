import TestSupport
import XCTest

/// The journey of a parent who moves an item between their child's lists, against a real test server. From the
/// Lists tab, the child's primary list, then the item's page, where Move to… in the menu opens the picker. A tap on
/// the child's other list moves the item there at once: the page stays, with the new list's name, which pushes that
/// list's page with the item on it. The server has the item on that list. See "Every drag has a way without
/// dragging", "What the windows show after a drop" and "A page that goes away under a window" in `docs/spec.md`, and
/// Move to… in `docs/screens/item.md` and `docs/screens/list.md`.
///
/// It audits the picker, and attaches a screenshot of it as evidence for a person.
nonisolated final class MoveJourney: JourneyTestCase {
  @MainActor
  func testMove() async {
    continueAfterFailure = false
    // XCTest reports an error that a test throws at the place of the last error thrown anywhere, even one that
    // was caught. So the journey catches its own error, and fails with it here.
    do {
      try await move()
    } catch {
      XCTFail("\(error)")
    }
  }

  @MainActor
  private func move() async throws {
    let server = try await TestServer.shared()
    let builder = try await FixtureBuilder(server: server)
    let farOff = FixtureBuilder.monthAndDay(daysFromNow: Audit.farOff)
    let dana = try await builder.person("Dana", birthday: farOff)
    // A user who confirmed their profile, so the app shows them no profile gate.
    try await builder.confirmProfile(of: dana)
    let emma = try await builder.person("Emma", birthday: farOff, parents: [dana])
    let primary = try await builder.primaryList(of: emma)
    let toys = try await builder.list("Toys", of: emma)
    let kite = try await builder.item(builder.name("Kite"), on: primary, as: emma)

    // Signed in as the parent.
    let app = Audit.app()
    app.launchEnvironment["WISHBONE_JOURNEY_START_SIGNED_OUT"] = "1"
    app.launchEnvironment["WISHBONE_JOURNEY_LOGIN_LINK"] = try await builder.loginLink(for: dana).absoluteString
    app.launch()
    let starting = { (words: String) in
      app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", words)).firstMatch
    }
    let lists = app.tabBars.firstMatch.buttons[Audit.words("Lists")]
    XCTAssertTrue(lists.waitForExistence(timeout: 60), "The tabs didn't show after the sign-in.")

    // The Lists tab, with Emma's lists under her name, then her primary list's page with the item.
    lists.tap()
    let listRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", primary.name)).firstMatch
    XCTAssertTrue(listRow.waitForExistence(timeout: 30), "The Lists tab has no row for Emma's list.")
    listRow.tap()
    let itemRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", kite.title)).firstMatch
    XCTAssertTrue(itemRow.waitForExistence(timeout: 30), "Emma's list has no row for the item.")

    // The item's page, and Move to… in its menu.
    itemRow.tap()
    let more = app.navigationBars.buttons[Audit.words("More")].firstMatch
    XCTAssertTrue(more.waitForExistence(timeout: 10), "The item's page has no menu.")
    more.tap()
    let moveTo = app.buttons[Audit.words("Move to…")]
    XCTAssertTrue(moveTo.waitForExistence(timeout: 10), "The menu has no Move to….")
    moveTo.tap()

    // The picker: Dana's own list, and Emma's other list under her name, with her name, never the list it is on.
    let picker = app.navigationBars[Audit.words("Move to…")]
    XCTAssertTrue(picker.waitForExistence(timeout: 10), "Move to… didn't open the picker.")
    let target = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", toys.name)).firstMatch
    XCTAssertTrue(target.waitForExistence(timeout: 10), "The picker has no row for Emma's other list.")
    XCTAssertTrue(target.label.contains(emma.name), "The picker's row doesn't name the list's recipient.")
    XCTAssertFalse(
      app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", primary.name)).firstMatch.exists,
      "The picker offers the list that the item is on.")
    try await Audit.run(on: app, showing: "the Move to… picker", in: self)

    // A tap moves the item at once. The picker closes, and the item's page stays, with the new list's name.
    target.tap()
    XCTAssertTrue(picker.waitForNonExistence(timeout: 10), "The picker didn't close.")
    let newList = app.buttons[toys.name]
    XCTAssertTrue(newList.waitForExistence(timeout: 10), "The item's page doesn't name its new list.")

    // The new list's page has the item.
    newList.tap()
    XCTAssertTrue(app.navigationBars[toys.name].waitForExistence(timeout: 10), "The new list's page didn't show.")
    XCTAssertTrue(starting(kite.title).waitForExistence(timeout: 10), "The new list's page has no row for the item.")

    // The server has the item on the new list.
    let isMoved = try await isOnServer(kite.id, on: toys.id, as: dana)
    XCTAssertTrue(isMoved, "The server doesn't have the item on the new list.")
    app.terminate()
  }

  /// Whether the server has the item on the list. The app sends the move behind the tap, so this asks until the
  /// server has it, and gives up after a long time.
  @MainActor
  private func isOnServer(_ item: String, on list: String, as parent: Fixture.Person) async throws -> Bool {
    let session = try parent.signedIn()
    for _ in 0..<60 {
      if try await session.get("/items/\(item)")["list_id"].string == list { return true }
      try await Task.sleep(for: .milliseconds(500))
    }
    return false
  }
}
