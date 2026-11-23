import TestSupport
import XCTest

/// The journey of a giver who claims and marks bought, against a real test server. From Home, a person's page, then
/// an item's page, where I'll get this claims one, and the line of the gift takes the button's place. Then Gifts,
/// where the gift's toggle marks it bought, at once, and the server has it soon after. See "Claims are online only"
/// and "Unsent changes" in `docs/spec.md`, `docs/screens/item.md`, `docs/screens/gifts.md`, and "The simulator
/// tier" in `docs/development.md`.
///
/// It audits Home, the person's page, the item's page, and Giving with the gift, and attaches a screenshot of each
/// as evidence for a person.
nonisolated final class ClaimJourney: JourneyTestCase {
  @MainActor
  func testClaim() async {
    continueAfterFailure = false
    // XCTest reports an error that a test throws at the place of the last error thrown anywhere, even one that
    // was caught. So the journey catches its own error, and fails with it here.
    do {
      try await claim()
    } catch {
      XCTFail("\(error)")
    }
  }

  @MainActor
  private func claim() async throws {
    let server = try await TestServer.shared()
    let builder = try await FixtureBuilder(server: server)
    // Both birthdays are far off on every date, so Home has nothing in the next 60 days whenever the journey runs.
    // The person's page names Morgan's birthday, whose month changes with the date.
    let farOff = FixtureBuilder.monthAndDay(daysFromNow: Audit.farOff)
    let robin = try await builder.person("Robin", birthday: farOff)
    // A user who confirmed their profile, so the app shows them no profile gate.
    try await builder.confirmProfile(of: robin)
    let morgan = try await builder.person("Morgan", birthday: farOff)
    _ = try await builder.group("Family", users: [robin, morgan])
    let list = try await builder.primaryList(of: morgan)
    let title = builder.name("Kite")
    let kite = try await builder.item(title, on: list, as: morgan, quantity: 2)

    // Signed in as the giver, on Home.
    let app = Audit.app()
    // Text that holds the words. In the double-length pseudo-language, iOS doubles a string whose numbers it puts
    // in by their places as "1$lld of 2$lld still wanted 2 of 2 still wanted", so only the end holds the words.
    let holding = { (words: String) in
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }
    app.launchEnvironment["WISHBONE_JOURNEY_START_SIGNED_OUT"] = "1"
    app.launchEnvironment["WISHBONE_JOURNEY_LOGIN_LINK"] = try await builder.loginLink(for: robin).absoluteString
    app.launch()
    let person = app.buttons[morgan.name].firstMatch
    XCTAssertTrue(person.waitForExistence(timeout: 60), "Home didn't show after the sign-in.")
    // Home has nothing in the next 60 days, so the countdown and Coming up each say so. Coming up is last, and its
    // line goes on under the tab bar, where the Dynamic Type check can't measure it. It is allowed as in the
    // sign-in journey, and never at the largest text size.
    XCTAssertTrue(
      app.descendants(matching: .any)
        .matching(NSPredicate(format: "label == %@", Audit.words("Nothing in the next 60 days."))).firstMatch.exists,
      "Home has an occasion in the next 60 days.")
    try await Audit.run(
      on: app, showing: "Home", in: self, rowsThatLeaveTheScreen: ["Nothing in the next 60 days."])

    // The person's page, with the item's row.
    person.tap()
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", kite.title)).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10), "\(morgan.name)'s page has no row for the item.")
    try await Audit.run(on: app, showing: "a person's page", in: self)

    // The item's page: how many are still wanted, then I'll get this.
    row.tap()
    let claim = app.buttons[Audit.words("I'll get this")]
    XCTAssertTrue(claim.waitForExistence(timeout: 10), "The item's page has no I'll get this.")
    XCTAssertTrue(holding("2 of 2 still wanted").exists, "The page doesn't say how many.")
    // How many, and the button, are the last rows: a larger text pushes them off the screen. The journey doesn't
    // scroll to them at the largest text size: the audit of the scrolled screen reports issues with no element, so
    // they can't be told apart. In the double-length pseudo-language, how many starts "1$lld of 2$lld" (see above).
    try await Audit.run(
      on: app, showing: "an item's page", in: self,
      rowsThatLeaveTheScreen: ["2 of 2 still wanted", "1$lld of 2$lld still wanted", "I'll get this"])

    // The claim waits for the server. Then the line, which names the occasion, takes the button's place, and one
    // fewer is still wanted.
    claim.tap()
    let line = holding("You claimed 1 for ")
    XCTAssertTrue(line.waitForExistence(timeout: 30), "The line of the gift didn't show after the claim.")
    XCTAssertFalse(claim.exists, "I'll get this still shows after the claim.")
    XCTAssertTrue(holding("1 of 2 still wanted").exists, "The page doesn't show one fewer.")

    // The server has the gift.
    let gifts = try await robin.signedIn().get("/gifts?item_id=\(kite.id)&giver_id=me&state=open")
    XCTAssertEqual(gifts["data"].array?.count, 1, "The server has no gift of the claim.")
    let gift = try XCTUnwrap(gifts["data"].array?.first?["id"].string, "The server's gift has no ID.")

    // Gifts: the gift is in Giving, not bought, with its toggle.
    app.tabBars.firstMatch.buttons[Audit.words("Gifts")].tap()
    let bought = app.switches[Audit.words("Bought")].firstMatch
    XCTAssertTrue(bought.waitForExistence(timeout: 30), "Giving has no bought toggle.")
    XCTAssertEqual(bought.value as? String, "0", "The gift shows bought before the toggle.")
    try await Audit.run(on: app, showing: "Giving", in: self)

    // Mark bought is an unsent change: the toggle shows it at once, and the app sends it behind.
    bought.tap()
    let isOn = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: bought)
    XCTAssertEqual(XCTWaiter().wait(for: [isOn], timeout: 10), .completed, "The toggle didn't show the gift bought.")
    let isBought = try await isBoughtOnServer(gift, as: robin)
    XCTAssertTrue(isBought, "The server doesn't have the gift bought.")
    app.terminate()
  }

  /// Whether the server has the giver's gift bought. The app sends the change behind the toggle, so this asks until
  /// the server has it, and gives up after a long time.
  @MainActor
  private func isBoughtOnServer(_ gift: String, as giver: Fixture.Person) async throws -> Bool {
    let session = try giver.signedIn()
    for _ in 0..<60 {
      if try await session.get("/gifts/\(gift)")["is_bought"].bool == true { return true }
      try await Task.sleep(for: .milliseconds(500))
    }
    return false
  }
}
