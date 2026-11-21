import TestSupport
import XCTest

/// The sign-in journey: the app, launched with a login link as if pasted, reaches the tabs behind the signed-out
/// screen, against a real test server. Before it signs in, it opens the help sheet and the Share diagnostics sheet.
/// Then it visits each tab, and the Add screen that the plus opens. See "The simulator tier" in
/// `docs/development.md`.
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

    // The help sheet: the four ways to get a link, the last with its web link. The journey doesn't follow the
    // link, which would leave the app for the browser.
    app.buttons[Audit.words("I don't have a link")].tap()
    let help = app.staticTexts[Audit.words("Getting a login link")]
    XCTAssertTrue(help.waitForExistence(timeout: 10), "The help sheet didn't show.")
    XCTAssertTrue(app.staticTexts[Audit.words("Nobody in your family runs Wishbone yet.")].exists)
    let runningYourOwn = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", Audit.words("Running your own Wishbone"))).firstMatch
    XCTAssertTrue(runningYourOwn.exists, "The help sheet has no link on running your own Wishbone.")
    try await Audit.run(
      on: app, showing: "the help sheet", in: self,
      // The rows under the first, which the larger text, or the double-length words, push down and off.
      rowsThatLeaveTheScreen: [
        "You use Wishbone in a browser.", "You're signed in to the app on another device.",
        "Nobody in your family runs Wishbone yet.",
        "Running your own Wishbone",
      ])
    // The sheet's close button has the system's words, so the journey finds it by its place.
    app.navigationBars.firstMatch.buttons.firstMatch.tap()
    XCTAssertTrue(scan.waitForExistence(timeout: 10))
    XCTAssertFalse(help.exists, "The help sheet didn't close.")

    // The notice line opens Share diagnostics as a sheet: the switch, on by default, what is sent, and the link to
    // the privacy policy. The journey doesn't turn the switch, which is the device's, or follow the link.
    app.buttons[Audit.words("Diagnostics settings")].tap()
    let share = app.switches[Audit.words("Share diagnostics")]
    XCTAssertTrue(share.waitForExistence(timeout: 10), "The Share diagnostics sheet didn't show.")
    XCTAssertEqual(share.value as? String, "1", "Diagnostics are not on by default.")
    let privacyPolicy = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", Audit.words("Privacy policy"))).firstMatch
    XCTAssertTrue(privacyPolicy.exists, "The Share diagnostics sheet has no link to the privacy policy.")
    // The Dynamic Type check reports the web link row as "partially unsupported" in the default settings, where the
    // row is on the screen whole, as it does the help sheet's link row. It is allowed as there, and never at the
    // largest text size, where the check measures every row that shows.
    try await Audit.run(
      on: app, showing: "the Share diagnostics sheet", in: self, rowsThatLeaveTheScreen: ["Privacy policy"])
    app.navigationBars[Audit.words("Share diagnostics")].buttons[Audit.words("Done")].tap()
    XCTAssertTrue(scan.waitForExistence(timeout: 10))
    XCTAssertFalse(share.exists, "The Share diagnostics sheet didn't close.")
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
    // and the keyboard goes.
    field.typeText("Kite\n")
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10), "The keyboard didn't go.")
    XCTAssertEqual(field.value as? String, "Kite")
    // The audit is of the app's screen, not of the system keyboard. Once the keyboard has shown in a launch, it
    // stays in the app when it hides, and the audit lays it out again hundreds of times: on a slow runner, past
    // the audit's time limit. The app gives up the keyboard when it leaves the foreground, so the journey sends it
    // to the Home Screen and back first. The screen comes back as it was, with the words in the field.
    XCUIDevice.shared.press(.home)
    let left = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in app.state != .runningForeground }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [left], timeout: 10), .completed, "The app didn't leave the foreground.")
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "The app didn't come back.")
    XCTAssertTrue(field.waitForExistence(timeout: 10), "The Add screen didn't come back.")
    XCTAssertEqual(field.value as? String, "Kite")
    XCTAssertFalse(app.keyboards.firstMatch.exists, "The keyboard came back with the app.")
    try await Audit.run(on: app, showing: "the Add screen", in: self)
    app.terminate()
  }
}
