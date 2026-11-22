import TestSupport
import XCTest

/// The journey of a giver who claims and marks bought, against a real test server: the claim half. From Home, a
/// person's page, then an item's page, where I'll get this claims one, and the line of the gift takes the button's
/// place. See "Claims are online only" in `docs/spec.md`, `docs/screens/item.md`, and "The simulator tier" in
/// `docs/development.md`.
///
/// It audits Home, the person's page and the item's page, and attaches a screenshot of each as evidence for a
/// person.
nonisolated final class ClaimJourney: XCTestCase {
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
    let robin = try await builder.person("Robin")
    // A user who confirmed their profile, so the app shows them no profile gate.
    try await builder.confirmProfile(of: robin)
    let morgan = try await builder.person("Morgan")
    _ = try await builder.group("Family", users: [robin, morgan])
    let list = try await builder.primaryList(of: morgan)
    let title = builder.name("Kite")
    let kite = try await builder.item(title, on: list, as: morgan, quantity: 2)

    // Signed in as the giver, on Home.
    let app = Audit.app()
    app.launchEnvironment["WISHBONE_JOURNEY_START_SIGNED_OUT"] = "1"
    app.launchEnvironment["WISHBONE_JOURNEY_LOGIN_LINK"] = try await builder.loginLink(for: robin).absoluteString
    app.launch()
    let person = app.buttons[morgan.name].firstMatch
    XCTAssertTrue(person.waitForExistence(timeout: 60), "Home didn't show after the sign-in.")
    try await Audit.run(on: app, showing: "Home", in: self)

    // The person's page, with the item's row.
    person.tap()
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", kite.title)).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10), "\(morgan.name)'s page has no row for the item.")
    try await Audit.run(on: app, showing: "a person's page", in: self)

    // The item's page: how many are still wanted, then I'll get this.
    row.tap()
    let claim = app.buttons[Audit.words("I'll get this")]
    XCTAssertTrue(claim.waitForExistence(timeout: 10), "The item's page has no I'll get this.")
    XCTAssertTrue(app.staticTexts[Audit.words("2 of 2 still wanted")].exists, "The page doesn't say how many.")
    // How many, and the button, are the last rows: a larger text pushes them off the screen. The journey doesn't
    // scroll to them at the largest text size: the audit of the scrolled screen reports issues with no element, so
    // they can't be told apart.
    try await Audit.run(
      on: app, showing: "an item's page", in: self, rowsThatLeaveTheScreen: ["2 of 2 still wanted", "I'll get this"])

    // The claim waits for the server. Then the line, which names the occasion, takes the button's place, and one
    // fewer is still wanted.
    claim.tap()
    let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "You claimed 1 for ")).firstMatch
    XCTAssertTrue(line.waitForExistence(timeout: 30), "The line of the gift didn't show after the claim.")
    XCTAssertFalse(claim.exists, "I'll get this still shows after the claim.")
    XCTAssertTrue(app.staticTexts[Audit.words("1 of 2 still wanted")].exists, "The page doesn't show one fewer.")

    // The server has the gift.
    let gifts = try await robin.signedIn().get("/gifts?item_id=\(kite.id)&giver_id=me&state=open")
    XCTAssertEqual(gifts["data"].array?.count, 1, "The server has no gift of the claim.")
    app.terminate()
  }
}
