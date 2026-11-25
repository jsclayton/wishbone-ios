import TestSupport
import XCTest

/// The journey of a giver who drops two gifts, against a real test server. In Giving, a row's swipe action I won't
/// get this asks to confirm, and after the confirmation the row leaves Giving. Then a gift's page, where I won't get
/// this at the foot asks the same, and after it the page closes back to Giving, never to the "not found" page. See
/// "I won't get this" in `docs/screens/gifts.md` and `docs/screens/gift.md`, and "The simulator tier" in
/// `docs/development.md`.
///
/// It audits Giving with the gifts, a gift's page, and Giving when it is empty, and attaches a screenshot of each as
/// evidence for a person.
nonisolated final class DropGiftJourney: JourneyTestCase {
  @MainActor
  func testDropGift() async {
    continueAfterFailure = false
    // XCTest reports an error that a test throws at the place of the last error thrown anywhere, even one that
    // was caught. So the journey catches its own error, and fails with it here.
    do {
      try await dropGifts()
    } catch {
      XCTFail("\(error)")
    }
  }

  @MainActor
  private func dropGifts() async throws {
    let server = try await TestServer.shared()
    let builder = try await FixtureBuilder(server: server)
    let farOff = FixtureBuilder.monthAndDay(daysFromNow: Audit.farOff)
    let robin = try await builder.person("Robin", birthday: farOff)
    // A user who confirmed their profile, so the app shows them no profile gate.
    try await builder.confirmProfile(of: robin)
    let morgan = try await builder.person("Morgan", birthday: farOff)
    _ = try await builder.group("Family", users: [robin, morgan])
    let list = try await builder.primaryList(of: morgan)
    // The giver has two gifts. The claim journey proves the claim itself, so these come from the server.
    let kite = try await builder.item(builder.name("Kite"), on: list, as: morgan)
    let drum = try await builder.item(builder.name("Snare drum with a stand and sticks"), on: list, as: morgan)
    _ = try await builder.claim(kite, as: robin)
    // The second gift's page must have no text that starts under the tab bar and ends on the screen: the contrast
    // check reads it against the bar's glass, and no exception allows it. So the page is longer than the screen. Its
    // long note puts I won't get this, at the foot, below the screen as the page opens, and the note's own row starts
    // above the bar. At the largest text size, its long title puts the For line across the bar's top edge, and
    // Bought below the screen. At that size, the audit scrolls to the foot.
    let note = (1...10).map { "Line \($0) of the note." }.joined(separator: "\n")
    _ = try await builder.claim(drum, as: robin, note: note)

    // Signed in as the giver, on Home.
    let app = Audit.app()
    app.launchEnvironment["WISHBONE_JOURNEY_START_SIGNED_OUT"] = "1"
    app.launchEnvironment["WISHBONE_JOURNEY_LOGIN_LINK"] = try await builder.loginLink(for: robin).absoluteString
    app.launch()
    XCTAssertTrue(
      app.buttons[morgan.name].firstMatch.waitForExistence(timeout: 60), "Home didn't show after the sign-in.")

    // Giving, with a row for each gift. A row's gift opens the gift's page, and its title starts its words.
    let row = { (item: Fixture.Item) in
      app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", item.title)).firstMatch
    }
    app.tabBars.firstMatch.buttons[Audit.words("Gifts")].tap()
    XCTAssertTrue(row(kite).waitForExistence(timeout: 30), "Giving has no row for the first gift.")
    XCTAssertTrue(row(drum).waitForExistence(timeout: 30), "Giving has no row for the second gift.")
    try await Audit.run(on: app, showing: "Giving", in: self)

    // The swipe action on the first row asks to confirm, and the row stays until the giver does.
    let wontGetThis = Audit.words("I won't get this")
    app.cells.containing(NSPredicate(format: "label BEGINSWITH %@", kite.title)).firstMatch.swipeLeft()
    let swipeAction = app.buttons[wontGetThis].firstMatch
    XCTAssertTrue(swipeAction.waitForExistence(timeout: 10), "The row's swipe action has no I won't get this.")
    swipeAction.tap()
    try confirm(in: app, with: wontGetThis)
    XCTAssertTrue(gone(row(kite)), "The row stayed in Giving after I won't get this.")
    XCTAssertTrue(row(drum).exists, "The other gift's row left Giving too.")
    let isDropped = try await isDroppedOnServer(kite, as: robin)
    XCTAssertTrue(isDropped, "The server still has the first gift.")

    // The other gift's page, with its note. I won't get this is the row at its foot, below the screen.
    row(drum).tap()
    XCTAssertTrue(
      app.navigationBars[Audit.words("Gift")].waitForExistence(timeout: 10), "The gift's page didn't open.")
    XCTAssertTrue(
      app.descendants(matching: .any).matching(NSPredicate(format: "value BEGINSWITH %@", "Line 1 of the note."))
        .firstMatch.waitForExistence(timeout: 10),
      "The gift's page doesn't show the note.")
    // The rows from Bought down go off the screen as the text grows. At the largest text size, the audit scrolls to
    // I won't get this.
    let pageRows = [
      "Bought", "How many", "1", "Occasion", "Birthday", "Hidden until", "From", "Note", "Only you see this note.",
    ]
    try await Audit.run(
      on: app, showing: "a gift's page", in: self, rowsThatLeaveTheScreen: pageRows,
      rowsToScrollTo: ["I won't get this"])

    // The page scrolls to its foot: a list makes a row only near the screen. A scroll is not an action, so the
    // row is still reached through its own button.
    let foot = app.buttons[wontGetThis].firstMatch
    for _ in 0..<5 where !(foot.exists && foot.isHittable) {
      app.swipeUp(velocity: .slow)
    }
    XCTAssertTrue(foot.waitForExistence(timeout: 10), "The gift's page has no I won't get this.")

    // After the confirmation, the page closes back to Giving, which is now empty, and never shows "not found".
    foot.tap()
    try confirm(in: app, with: wontGetThis)
    let empty = app.staticTexts[
      Audit.words("You aren't getting anything yet. Open someone on Home and tap I'll get this.")
    ]
    XCTAssertTrue(empty.waitForExistence(timeout: 10), "The page didn't close back to an empty Giving.")
    XCTAssertFalse(app.navigationBars[Audit.words("Gift")].exists, "The gift's page is still open.")
    XCTAssertFalse(
      app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "This is gone")).firstMatch
        .exists,
      "The window shows the not-found page.")
    let isAlsoDropped = try await isDroppedOnServer(drum, as: robin)
    XCTAssertTrue(isAlsoDropped, "The server still has the second gift.")
    try await Audit.run(on: app, showing: "Giving, when it is empty", in: self)
    app.terminate()
  }

  /// Taps the confirmation's button. The confirmation asks "You won't get {title}?", and its button has the same
  /// words as the action that opened it, so the journey finds the button inside the confirmation.
  @MainActor
  private func confirm(in app: XCUIApplication, with words: String) throws {
    let dialog = app.sheets.firstMatch
    XCTAssertTrue(dialog.waitForExistence(timeout: 10), "I won't get this didn't ask to confirm.")
    dialog.buttons[words].tap()
    XCTAssertTrue(gone(dialog), "The confirmation stayed after its button.")
  }

  /// Whether the element goes, within a while.
  @MainActor
  private func gone(_ element: XCUIElement) -> Bool {
    let isGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
    return XCTWaiter().wait(for: [isGone], timeout: 10) == .completed
  }

  /// Whether the server has no open gift of the giver's on the item. The app sends I won't get this behind the
  /// confirmation, so this asks until the server has it, and gives up after a long time.
  @MainActor
  private func isDroppedOnServer(_ item: Fixture.Item, as giver: Fixture.Person) async throws -> Bool {
    let session = try giver.signedIn()
    for _ in 0..<60 {
      let gifts = try await session.get("/gifts?item_id=\(item.id)&giver_id=me&state=open")
      if gifts["data"].array?.isEmpty == true { return true }
      try await Task.sleep(for: .milliseconds(500))
    }
    return false
  }
}
