import TestSupport
import XCTest

/// The add-an-item journey: the plus, typed words, the add form, Add, the "Added" row, and the item's page, against
/// a real test server. See "Adding an item" in `docs/spec.md`, `docs/screens/add.md`, and
/// `docs/screens/add-form.md`.
///
/// It audits the add form, and the Add screen with its "Added" row, and attaches a screenshot of each as evidence
/// for a person.
nonisolated final class AddItemJourney: JourneyTestCase {
  @MainActor
  func testAddItem() async {
    continueAfterFailure = false
    // XCTest reports an error that a test throws at the place of the last error thrown anywhere, even one that
    // was caught. So the journey catches its own error, and fails with it here.
    do {
      try await addItem()
    } catch {
      XCTFail("\(error)")
    }
  }

  @MainActor
  private func addItem() async throws {
    let server = try await TestServer.shared()
    let builder = try await FixtureBuilder(server: server)
    let robin = try await builder.person("Robin")
    // A user who confirmed their profile, so the app shows them no profile gate.
    try await builder.confirmProfile(of: robin)
    let list = try await builder.primaryList(of: robin)
    let title = builder.name("A book about sharks")

    let app = Audit.app()
    app.launchEnvironment["WISHBONE_JOURNEY_START_SIGNED_OUT"] = "1"
    app.launchEnvironment["WISHBONE_JOURNEY_LOGIN_LINK"] = try await builder.loginLink(for: robin).absoluteString
    app.launch()
    let tabs = app.tabBars.firstMatch
    XCTAssertTrue(tabs.buttons[Audit.words("Add")].waitForExistence(timeout: 60), "The tabs didn't show.")

    // The plus, and the typed words. The keyboard's Search key searches them.
    // On 2026-11-23, in a local gate run in the double-length pseudo-language, the field wasn't there 10 seconds
    // after the tap. The wait ends when the field shows, so a long limit costs a passing run nothing.
    tabs.buttons[Audit.words("Add")].tap()
    let field = app.searchFields[Audit.words("Paste a link or type what you want")]
    XCTAssertTrue(field.waitForExistence(timeout: 30), "The Add screen's field didn't show.")
    field.typeText("\(title)\n")

    // The add form is pushed, with the words as the title, and Add in its bar.
    let form = app.navigationBars[Audit.words("Add item")]
    XCTAssertTrue(form.waitForExistence(timeout: 30), "The add form didn't show after the search.")
    // The title wraps, so its field is a text view or a text field, by the system's choice. It holds the words.
    let titleField = app.descendants(matching: .any).matching(
      NSPredicate(
        format: "value == %@ AND (elementType == %d OR elementType == %d)", title,
        XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue)
    ).firstMatch
    XCTAssertTrue(titleField.waitForExistence(timeout: 10), "The add form's title isn't the typed words.")
    // The back button reads "Add" too, as the Add screen's title, so Add is the last button with the word.
    let add = try XCTUnwrap(
      form.buttons.matching(NSPredicate(format: "label == %@", Audit.words("Add"))).allElementsBoundByIndex.last,
      "The add form has no Add.")
    XCTAssertTrue(add.isEnabled, "Add is disabled on a form with a title.")
    dropKeyboard(of: app)
    XCTAssertTrue(form.waitForExistence(timeout: 30), "The add form didn't come back.")
    try await Audit.run(on: app, showing: "the add form", in: self)

    // Add: the form closes, the field is empty, and the "Added" row names the item and the list. In the
    // double-length pseudo-language iOS doubles the format, so the row is found by the title and the list.
    add.tap()
    let added = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", title, list.name)
    ).firstMatch
    XCTAssertTrue(added.waitForExistence(timeout: 30), "The Added row didn't show after Add.")
    XCTAssertFalse(form.exists, "The add form stayed open after Add.")
    XCTAssertNotEqual(field.value as? String, title, "The field still has the words after Add.")
    dropKeyboard(of: app)
    XCTAssertTrue(added.waitForExistence(timeout: 30), "The Added row didn't come back.")
    try await Audit.run(on: app, showing: "the Add screen after an add", in: self)

    // The row opens the item's page.
    added.tap()
    XCTAssertTrue(
      app.staticTexts[title].waitForExistence(timeout: 10), "The Added row didn't open the item's page.")
    XCTAssertTrue(app.buttons[list.name].exists, "The item's page doesn't name its list.")

    // Back to the Add screen: the user left it, so the row is gone.
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(field.waitForExistence(timeout: 10), "Back didn't show the Add screen.")
    XCTAssertFalse(added.exists, "The Added row stayed after the user left the screen.")
    app.terminate()
  }

  /// The audit is of the app's screen, not of the system keyboard. Once the keyboard has shown in a launch, it
  /// stays in the app when it hides, and the audit lays it out again hundreds of times. The app gives up the
  /// keyboard when it leaves the foreground, so the journey sends it to the Home Screen and back first, as the
  /// sign-in journey does.
  @MainActor
  private func dropKeyboard(of app: XCUIApplication) {
    sendHomeAndBack(app)
  }
}
