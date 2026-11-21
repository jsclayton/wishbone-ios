import TestSupport
import XCTest

/// The sign-in journey: the app, launched with a login link as if pasted, reaches the tabs behind the signed-out
/// screen, against a real test server. Then it visits each tab, and the Add screen that the plus opens. See "The
/// simulator tier" in `docs/development.md`.
///
/// It runs the accessibility audit on each screen that it reaches, and attaches a screenshot of each as evidence
/// for a person. A screenshot is never compared with a reference. Under the gate, it audits each screen in the four
/// settings, in one run.
nonisolated final class SignInJourney: XCTestCase {
  @MainActor
  func testSignIn() async {
    continueAfterFailure = false
    // XCTest reports an error that a test throws at the place of the last error thrown anywhere, even one that
    // was caught. So the journey catches its own error, and fails with it here.
    do {
      try await signIn()
    } catch {
      XCTFail("\(error)")
    }
  }

  @MainActor
  private func signIn() async throws {
    let server = try await TestServer.shared()
    let builder = try await FixtureBuilder(server: server)
    let robin = try await builder.person("Robin")
    let list = try await builder.primaryList(of: robin)
    for title in ["Kite", "Puzzle"] {
      _ = try await builder.item(title, on: list, as: robin)
    }

    // The signed-out screen.
    let app = Audit.app()
    app.launchEnvironment["WISHBONE_JOURNEY_START_SIGNED_OUT"] = "1"
    app.launch()
    let scan = app.buttons[Audit.words("Scan QR code")]
    XCTAssertTrue(scan.waitForExistence(timeout: 60), "The signed-out screen didn't show.")
    // The simulator has no camera, so the audit covers the "no camera" state of the screen.
    XCTAssertFalse(scan.isEnabled)
    XCTAssertTrue(app.staticTexts[Audit.words("This device has no camera to scan with. Paste a link.")].exists)
    try await Audit.run(on: app, showing: "the signed-out screen", in: self)
    app.terminate()

    // The same launch, with a login link passed in as if pasted.
    app.launchEnvironment["WISHBONE_JOURNEY_LOGIN_LINK"] = try await builder.loginLink(for: robin).absoluteString
    app.launch()
    XCTAssertTrue(app.staticTexts["Kite"].waitForExistence(timeout: 60), "Home didn't show after the sign-in.")
    XCTAssertTrue(app.staticTexts["Puzzle"].exists)
    XCTAssertTrue(app.navigationBars[robin.name].exists)

    // The tabs: Home, Lists, Gifts, and the plus, which reads "Add". A window opens on Home.
    let tabs = app.tabBars.firstMatch
    XCTAssertTrue(tabs.buttons[Audit.words("Home")].isSelected, "The window didn't open on Home.")
    for name in ["Lists", "Gifts", "Add"] {
      XCTAssertTrue(tabs.buttons[Audit.words(name)].exists, "The tab bar has no \(name).")
    }
    // The sidebar's shortcuts are not in a tab bar, so it never grows a "More" tab.
    XCTAssertFalse(tabs.buttons["More"].exists || tabs.buttons[Audit.words("More")].exists)
    try await Audit.run(on: app, showing: "Home", in: self)

    for name in ["Lists", "Gifts"] {
      tabs.buttons[Audit.words(name)].tap()
      XCTAssertTrue(app.navigationBars[Audit.words(name)].waitForExistence(timeout: 10), "\(name) didn't show.")
      XCTAssertTrue(tabs.buttons[Audit.words(name)].isSelected)
      try await Audit.run(on: app, showing: name, in: self)
    }

    // Home kept its place. Then the plus opens the Add screen, with the system search field and its prompt.
    tabs.buttons[Audit.words("Home")].tap()
    XCTAssertTrue(app.staticTexts["Kite"].waitForExistence(timeout: 10), "Home didn't show again.")
    tabs.buttons[Audit.words("Add")].tap()
    let field = app.searchFields[Audit.words("Paste a link or type what you want")]
    XCTAssertTrue(field.waitForExistence(timeout: 10), "The Add screen's field didn't show.")
    // The field is ready: the words go in with no tap on it first. The keyboard's Search key ends the typing,
    // and the keyboard goes. The audit is of the app's screen, and takes too long with the system keyboard on it.
    field.typeText("Kite\n")
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10), "The keyboard didn't go.")
    XCTAssertEqual(field.value as? String, "Kite")
    try await Audit.run(on: app, showing: "the Add screen", in: self)
    app.terminate()
  }
}
