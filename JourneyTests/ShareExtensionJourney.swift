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
    XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 60), "Safari didn't open the store's page.")
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
    app.activate()
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
