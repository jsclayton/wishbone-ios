import TestSupport
import XCTest

/// The people journey: from Home's People heading to the People page, then a person's page with their good to know,
/// their items and their other lists, then one of those lists, sorted by price, and back to the person by a
/// recipient's name. See `docs/screens/people.md`, `docs/screens/user.md` and `docs/screens/list.md`.
///
/// It runs the accessibility audit on each screen that it reaches, as the sign-in journey does.
nonisolated final class PeopleJourney: JourneyTestCase {
  @MainActor
  func testPeople() async {
    continueAfterFailure = false
    // XCTest reports an error that a test throws at the place of the last error thrown anywhere, even one that
    // was caught. So the journey catches its own error, and fails with it here.
    do {
      try await people()
    } catch {
      XCTFail("\(error)")
    }
  }

  @MainActor
  private func people() async throws {
    let server = try await TestServer.shared()
    let builder = try await FixtureBuilder(server: server)
    let robin = try await builder.person("Robin")
    try await builder.confirmProfile(of: robin)
    // Ash's good to know has a link with a bold word inside it, and a numbered list.
    let ash = try await builder.person("Ash")
    try await builder.goodToKnow(
      "Likes [**Lego** set](https://shop.example/lego) best.\n\n1. Size medium", of: ash)
    let primary = try await builder.primaryList(of: ash)
    // Always wanted, whose words fit on one line in the double-length pseudo-language too, so the page is short
    // enough that no row is under the tab bar.
    _ = try await builder.item(
      "Kite", on: primary, as: ash, isUnlimited: true,
      storeLinks: [(url: "https://shop.example/kite", priceMinor: 2000)])
    let camping = try await builder.list("Camping", of: ash)
    _ = try await builder.item(
      "Tent", on: camping, as: ash, storeLinks: [(url: "https://shop.example/tent", priceMinor: 10000)])
    _ = try await builder.item(
      "Lamp", on: camping, as: ash, storeLinks: [(url: "https://shop.example/lamp", priceMinor: 1500)])
    _ = try await builder.item("Stove", on: camping, as: ash)
    _ = try await builder.group("Family", users: [robin, ash])

    let app = Audit.app()
    app.launchEnvironment["WISHBONE_JOURNEY_START_SIGNED_OUT"] = "1"
    app.launchEnvironment["WISHBONE_JOURNEY_LOGIN_LINK"] = try await builder.loginLink(for: robin).absoluteString
    app.launch()
    XCTAssertTrue(app.buttons[ash.name].waitForExistence(timeout: 60), "Home didn't show after the sign-in.")
    let starting = { (words: String) in
      app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", words)).firstMatch
    }

    // Home's People heading pushes the People page, with Ash in the group's part.
    app.buttons[Audit.words("People")].firstMatch.tap()
    XCTAssertTrue(
      app.navigationBars[Audit.words("People")].waitForExistence(timeout: 10), "The People page didn't show.")
    XCTAssertTrue(app.buttons[ash.name].waitForExistence(timeout: 10), "The People page has no Ash.")
    try await Audit.run(on: app, showing: "the People page", in: self)

    // Ash's row pushes Ash's page.
    app.buttons[ash.name].firstMatch.tap()
    XCTAssertTrue(app.navigationBars[ash.name].waitForExistence(timeout: 10), "Ash's page didn't show.")
    XCTAssertTrue(starting("Kite").waitForExistence(timeout: 30), "Ash's page has no items.")
    XCTAssertTrue(app.staticTexts[Audit.words("Good to know")].exists, "Ash's page has no Good to know.")
    // The line reads as it shows, the bold word and all, and its link is a link of its own, so the Links rotor
    // reaches it and Voice Control takes its words.
    let line = app.staticTexts["Likes Lego set best."]
    XCTAssertTrue(line.exists, "The good to know line doesn't read as it shows.")
    XCTAssertTrue(app.links["Lego set"].exists, "The good to know line's link is not a link.")
    // Under the block, the link's row reads its words once, then "opens in browser".
    let linkRow = starting("Lego set,")
    XCTAssertTrue(linkRow.exists, "The good to know has no row for its link.")
    // In the double-length pseudo-language, the row's combined label has a stray comma between its parts, so the
    // journey checks the words once, at the start, and "opens in browser" at the end.
    XCTAssertEqual(linkRow.label.components(separatedBy: "Lego set").count, 2, "The link's row reads its words twice.")
    XCTAssertTrue(
      linkRow.label.hasSuffix(Audit.words("opens in browser")), "The link's row doesn't read \"opens in browser\".")
    // A numbered list reads its numbers.
    XCTAssertTrue(app.staticTexts["1"].exists, "The numbered list doesn't read its numbers.")
    XCTAssertTrue(app.staticTexts["Size medium"].exists)
    // The rows below Good to know's first line, which the larger text pushes down and off: the link's row, the
    // numbered list's number and item, the item and its price, Other lists' heading, and the other list with its
    // count. The page is short, so that no row is under the tab bar, where the audit measures the bar's glass. In
    // the double-length pseudo-language, iOS shows the count's plural string as its raw format, "#@value@
    // %#@value@", and the item reads "Always wanted Always wanted".
    let pageRows = [
      "Lego set", "1", "Size medium", "Kite", "$20", "Always wanted", "Other lists", camping.name, "3 items",
      "#@value@",
    ]
    try await Audit.run(
      on: app, showing: "a person's page", in: self, rowsThatLeaveTheScreen: pageRows,
      rowsToScrollTo: ["Lego set,", "Size medium", "Kite", camping.name])

    // A row of Other lists pushes that list's page.
    starting(camping.name).tap()
    XCTAssertTrue(app.navigationBars[camping.name].waitForExistence(timeout: 10), "The list's page didn't show.")
    XCTAssertTrue(starting("Tent").waitForExistence(timeout: 30), "The list's page has no items.")
    let listRows = ["Tent", "Lamp", "Stove"]
    try await Audit.run(
      on: app, showing: "a list's page", in: self, rowsThatLeaveTheScreen: listRows, rowsToScrollTo: listRows)

    // Sort, in the toolbar's menu, orders the items by price: the lowest first, and the item with no price last.
    app.navigationBars[camping.name].buttons[Audit.words("More")].tap()
    let sort = app.buttons[Audit.words("Sort")]
    XCTAssertTrue(sort.waitForExistence(timeout: 10), "The menu has no Sort.")
    sort.tap()
    let price = app.buttons[Audit.words("Price")]
    XCTAssertTrue(price.waitForExistence(timeout: 10), "Sort has no Price.")
    price.tap()
    XCTAssertTrue(price.waitForNonExistence(timeout: 10), "The Sort menu didn't close.")
    // The rows move to their new places with the system's motion, so the journey waits for the order.
    let top = { (title: String) in starting(title).frame.minY }
    let sorted = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in top("Lamp") < top("Tent") && top("Tent") < top("Stove") }, object: nil)
    XCTAssertEqual(
      XCTWaiter.wait(for: [sorted], timeout: 10), .completed,
      "Sort by Price didn't order the items Lamp, Tent, Stove: \(top("Lamp")), \(top("Tent")), \(top("Stove")).")

    // A recipient's name on the For line is a link to their page.
    let recipient = app.links[ash.name]
    XCTAssertTrue(recipient.exists, "The For line's name is not a link.")
    recipient.tap()
    XCTAssertTrue(
      starting("Kite").waitForExistence(timeout: 10) && app.navigationBars[ash.name].exists,
      "The recipient's name didn't open their page.")
    app.terminate()
  }
}
