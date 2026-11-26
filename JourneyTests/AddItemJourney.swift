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

    try openTheDuplicate(titled: title, on: list.name, in: app)
    app.terminate()
  }

  /// The same title again: the form says that the list has the item already. The hint pushes the item's page over
  /// the form, and Back returns to the form with its typed changes. Back from the changed form then asks.
  @MainActor
  private func openTheDuplicate(titled title: String, on listName: String, in app: XCUIApplication) throws {
    let field = app.searchFields[Audit.words("Paste a link or type what you want")]
    field.tap()
    field.typeText("\(title)\n")
    let form = app.navigationBars[Audit.words("Add item")]
    XCTAssertTrue(form.waitForExistence(timeout: 30), "The add form didn't show for the same title.")

    // A typed change, which the form must keep under the item's page. The search put the typed words in the notes
    // too, so the notes are the second field that holds them.
    let notes = "For the beach"
    let typed = inputs(valued: title, in: app)
    XCTAssertTrue(
      typed.element(boundBy: 1).waitForExistence(timeout: 10), "The add form's notes aren't the typed words.")
    typed.element(boundBy: 1).tap()
    typed.element(boundBy: 1).typeText(" \(notes)")
    dropKeyboard(of: app)
    XCTAssertTrue(form.waitForExistence(timeout: 30), "The add form didn't come back.")

    // In the double-length pseudo-language iOS doubles the format, so the hint is found by its start and the title.
    let hint = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Already on this list:", title)
    ).firstMatch
    XCTAssertTrue(hint.waitForExistence(timeout: 10), "The add form has no hint for a title that the list has.")
    hint.tap()
    XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10), "The hint didn't open the item's page.")
    XCTAssertTrue(app.buttons[listName].exists, "The hint's page doesn't name the item's list.")
    XCTAssertFalse(form.exists, "The add form shows over the item's page.")

    // Back: the form, with the title and the typed notes still in it.
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(form.waitForExistence(timeout: 10), "Back from the hint's page didn't return to the add form.")
    XCTAssertTrue(
      inputs(valued: title, in: app).firstMatch.waitForExistence(timeout: 10),
      "The add form lost its title under the page.")
    XCTAssertTrue(
      inputs(containing: notes, in: app).firstMatch.exists, "The add form lost its typed notes under the page.")

    // Back from the changed form asks before it discards the item.
    form.buttons[Audit.words("Back")].tap()
    let discard = app.buttons[Audit.words("Discard")]
    XCTAssertTrue(discard.waitForExistence(timeout: 10), "Back from a changed form didn't ask.")
    discard.tap()
    XCTAssertTrue(field.waitForExistence(timeout: 10), "Discard didn't return to the Add screen.")
  }

  /// The fields and text views that hold exactly the words. A field that wraps is either one, by the system's choice.
  @MainActor
  private func inputs(valued value: String, in app: XCUIApplication) -> XCUIElementQuery {
    inputs(matching: NSPredicate(format: "value == %@", value), in: app)
  }

  /// The fields and text views whose words contain the words.
  @MainActor
  private func inputs(containing words: String, in app: XCUIApplication) -> XCUIElementQuery {
    inputs(matching: NSPredicate(format: "value CONTAINS %@", words), in: app)
  }

  @MainActor
  private func inputs(matching value: NSPredicate, in app: XCUIApplication) -> XCUIElementQuery {
    let kind = NSPredicate(
      format: "elementType == %d OR elementType == %d", XCUIElement.ElementType.textField.rawValue,
      XCUIElement.ElementType.textView.rawValue)
    return app.descendants(matching: .any).matching(NSCompoundPredicate(andPredicateWithSubpredicates: [value, kind]))
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
