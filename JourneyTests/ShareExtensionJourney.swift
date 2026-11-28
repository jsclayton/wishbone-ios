import TestSupport
import XCTest

/// The add-from-the-share-extension journey: a store's page in Safari, Share, Wishbone, the add form filled in from
/// the link, Add, and the item on the list in the app, against a real test server. See "The share extension" in
/// `docs/spec.md`, and `docs/screens/share-extension.md`.
///
/// It audits nothing. The share extension's view shows inside Safari, and an audit of Safari doesn't read it: on
/// 2026-11-26 a text of a contrast near 1:1 in the extension passed an audit of Safari, and failed the same audit in
/// the app. So the add form is audited in the app, by `AddItemJourney`.
///
/// The extension runs in a process of its own, which gets none of the app's launch arguments. So its words are the
/// String Catalog's English in every run, also in the double-length pseudo-language.
nonisolated final class ShareExtensionJourney: JourneyTestCase {
  @MainActor
  func testAddFromTheShareExtension() async {
    continueAfterFailure = false
    // XCTest reports an error that a test throws at the place of the last error thrown anywhere, even one that
    // was caught. So the journey catches its own error, and fails with it here.
    do {
      try await addFromTheShareExtension()
    } catch {
      XCTFail("\(error)")
    }
  }

  @MainActor
  private func addFromTheShareExtension() async throws {
    let server = try await TestServer.shared()
    let builder = try await FixtureBuilder(server: server)
    let robin = try await builder.person("Robin")
    // A user who confirmed their profile, so the app shows them no profile gate.
    try await builder.confirmProfile(of: robin)
    let list = try await builder.primaryList(of: robin)
    let page = try await StorePage(title: builder.name("A kite to share"), priceMinor: 2499, images: 1)

    // The app signs in, so the session keychain holds the session, and the shared container has the marker.
    let app = Audit.app()
    app.launchEnvironment["WISHBONE_JOURNEY_START_SIGNED_OUT"] = "1"
    app.launchEnvironment["WISHBONE_JOURNEY_LOGIN_LINK"] = try await builder.loginLink(for: robin).absoluteString
    app.launch()
    let lists = app.tabBars.firstMatch.buttons[Audit.words("Lists")]
    XCTAssertTrue(lists.waitForExistence(timeout: 60), "The tabs didn't show after the sign-in.")

    // The store's page in Safari, and Share in its page menu.
    let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
    XCUIDevice.shared.system.open(page.url)
    XCTAssertTrue(
      safari.wait(for: .runningForeground, timeout: Self.stateRecordTimeout), "Safari didn't open the store's page.")
    XCTAssertTrue(safari.staticTexts[page.title].waitForExistence(timeout: 60), "Safari didn't show the page.")
    let menu = safari.buttons["MoreMenuButton"]
    XCTAssertTrue(menu.waitForExistence(timeout: 30), "Safari has no page menu.")
    menu.tap()
    let share = safari.buttons["ShareButton"]
    XCTAssertTrue(share.waitForExistence(timeout: 30), "Safari's page menu has no Share.")
    share.tap()
    try openWishbone(in: safari)

    // The add form, filled in from the link, with Cancel and Add.
    let form = safari.navigationBars["Add item"]
    XCTAssertTrue(form.waitForExistence(timeout: 60), "The share extension's add form didn't show.")
    let title = safari.descendants(matching: .any).matching(
      NSPredicate(
        format: "value == %@ AND (elementType == %d OR elementType == %d)", page.title,
        XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue)
    ).firstMatch
    XCTAssertTrue(title.waitForExistence(timeout: 60), "The extension's form didn't take the page's title.")
    XCTAssertTrue(form.buttons["Cancel"].exists, "The extension's form has no Cancel.")
    try await attachScreenshot(of: safari, named: "The share extension's add form")
    let add = form.buttons["Add"]
    XCTAssertTrue(add.isEnabled, "Add is disabled on a form with a title.")

    // Add: the extension closes.
    add.tap()
    XCTAssertTrue(
      form.wait(for: \.exists, toEqual: false, timeout: 60), "The share extension stayed open after Add.")

    // In the app, the item is on the list.
    await bringBack(app)
    XCTAssertTrue(lists.waitForExistence(timeout: 60), "The app didn't come back.")
    lists.tap()
    // In the double-length pseudo-language, iOS puts a row's format places before its doubled words, so the row is
    // found by the words that it contains.
    let listRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", list.name)).firstMatch
    XCTAssertTrue(listRow.waitForExistence(timeout: 30), "The Lists tab has no row for Robin's list.")
    listRow.tap()
    let itemRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", page.title)).firstMatch
    XCTAssertTrue(itemRow.waitForExistence(timeout: 60), "The item from the share extension isn't on the list.")
    try await attachScreenshot(of: app, named: "The list with the item from the share extension")
    app.terminate()
    safari.terminate()
  }

  /// How long the journey waits for XCTest's record of an app's state. On 2026-11-27, in CI run 46046440049
  /// attempt 1, the record came 57 seconds after Safari came to the front, and hadn't come more than 60 seconds after
  /// the app came back: the named flake "XCTest's record of an app's state lags on a CI runner" in
  /// `docs/development.md`. A wait for a state that comes ends when it comes, so a long limit costs a passing run
  /// nothing.
  static let stateRecordTimeout: TimeInterval = 180

  /// Brings the app back to the front after the share. `activate()` waits at most 60 seconds for XCTest's record of
  /// the app's state, and fails when the record lags, though the app is in the front. So the journey expects only
  /// that failure, for this app, and then waits on the same record itself, for `stateRecordTimeout`. Any other
  /// failure in that span fails the journey. See the named flake "XCTest's record of an app's state lags on a CI
  /// runner" in `docs/development.md`.
  @MainActor
  private func bringBack(_ app: XCUIApplication) async {
    let options = XCTExpectedFailure.Options()
    options.isStrict = false
    options.issueMatcher = { issue in Self.isActivationLag(issue.compactDescription) }
    let start = Date.now
    // The gate lets this test pass with a known issue only with this reason: `allowedKnownIssues` in
    // `scripts/gate/steps.mjs`.
    continueAfterFailure = true
    XCTExpectFailure("XCTest's record of an app's state lags on a CI runner", options: options) {
      app.activate()
    }
    continueAfterFailure = false
    guard app.state != .runningForeground else { return }
    let caughtUp = app.wait(for: .runningForeground, timeout: Self.stateRecordTimeout)
    let seconds = Int(Date.now.timeIntervalSince(start).rounded())
    let record = caughtUp ? "the record said so after \(seconds) s" : "the record didn't say so within \(seconds) s"
    print("XCTest's activation of the app timed out on its record of the app's state: \(record).")
    await Audit.reportRetry("ShareExtensionJourney: \(record)", at: "activation-lags")
    XCTAssertTrue(
      caughtUp,
      "XCTest's record of the app's state didn't say Running Foreground within \(Int(Self.stateRecordTimeout)) "
        + "seconds of the activation.")
  }

  /// Whether an issue is `activate()`'s time-out on a lagging record of this app's state: the app's bundle, not the
  /// share extension's, and a record that says the app is still in the background.
  nonisolated static func isActivationLag(_ description: String) -> Bool {
    description.contains("Failed to activate application 'com.codemonkeylabs.wishbone at ")
      && description.contains("(current state: Running Background)")
  }

  /// Taps Wishbone in the share sheet: in its row of apps, or else under More, in the list of every app.
  @MainActor
  private func openWishbone(in safari: XCUIApplication) throws {
    let inRow = safari.cells.matching(NSPredicate(format: "label == %@", "Wishbone")).firstMatch
    let more = safari.cells.matching(NSPredicate(format: "label == %@", "More")).firstMatch
    XCTAssertTrue(more.waitForExistence(timeout: 30), "The share sheet didn't show.")
    if inRow.exists {
      inRow.tap()
      return
    }
    more.tap()
    let inList = safari.staticTexts.matching(NSPredicate(format: "label == %@", "Wishbone")).firstMatch
    XCTAssertTrue(inList.waitForExistence(timeout: 30), "The share sheet doesn't offer Wishbone for a web page.")
    inList.tap()
  }

  /// A screenshot as evidence for a person, never as pass or fail.
  @MainActor
  private func attachScreenshot(of app: XCUIApplication, named name: String) async throws {
    let attachment = XCTAttachment(screenshot: try await Screenshot.take(of: app, showing: name).screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
