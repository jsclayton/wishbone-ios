import TestSupport
import XCTest

/// The sign-out journey: from the tabs, the avatar opens Settings, and Sign out, after its warning, shows the
/// signed-out screen, against a real test server. See "Sign out" in `docs/spec.md`, and "The simulator tier" in
/// `docs/development.md`.
///
/// It audits the Settings sheet, and attaches a screenshot of it as evidence for a person.
nonisolated final class SignOutJourney: XCTestCase {
  @MainActor
  func testSignOut() async {
    continueAfterFailure = false
    // XCTest reports an error that a test throws at the place of the last error thrown anywhere, even one that
    // was caught. So the journey catches its own error, and fails with it here.
    do {
      try await signOut()
    } catch {
      XCTFail("\(error)")
    }
  }

  @MainActor
  private func signOut() async throws {
    let server = try await TestServer.shared()
    let builder = try await FixtureBuilder(server: server)
    let robin = try await builder.person("Robin")
    // A user who confirmed their profile, so the app shows them no profile gate.
    try await builder.confirmProfile(of: robin)
    let list = try await builder.primaryList(of: robin)
    _ = try await builder.item("Kite", on: list, as: robin)
    let link = try await builder.loginLink(for: robin).absoluteString
    let address = try XCTUnwrap(link.components(separatedBy: "/login/").first)

    // Signed in, on Home.
    let app = Audit.app()
    app.launchEnvironment["WISHBONE_JOURNEY_START_SIGNED_OUT"] = "1"
    app.launchEnvironment["WISHBONE_JOURNEY_LOGIN_LINK"] = link
    app.launch()
    XCTAssertTrue(app.staticTexts["Kite"].waitForExistence(timeout: 60), "Home didn't show after the sign-in.")

    // The avatar, at the top trailing corner, reads "Settings", and opens the Settings sheet.
    let avatar = app.navigationBars[robin.name].buttons[Audit.words("Settings")]
    XCTAssertTrue(avatar.waitForExistence(timeout: 10), "Home has no avatar.")
    avatar.tap()
    XCTAssertTrue(
      app.navigationBars[Audit.words("Settings")].waitForExistence(timeout: 10), "The Settings sheet didn't show.")

    // The Signed in block: the name, and the full address with its scheme.
    let signedIn = app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", robin.name, address)
    ).firstMatch
    XCTAssertTrue(signedIn.waitForExistence(timeout: 10), "Settings doesn't show the name and \(address).")
    try await Audit.run(
      on: app, showing: "Settings", in: self,
      rowsThatLeaveTheScreen: ["Share diagnostics", "About", "Source code", "Acknowledgements", "Version"])

    // Sign out, after its warning.
    app.buttons[Audit.words("Sign out")].tap()
    let warning = app.alerts[Audit.words("Sign out?")]
    XCTAssertTrue(warning.waitForExistence(timeout: 10), "Sign out gave no warning.")
    XCTAssertTrue(warning.staticTexts[Audit.words("You need a new login link to sign in again.")].exists)
    warning.buttons[Audit.words("Sign out")].tap()

    // The signed-out screen, with no message: the instance was reached.
    let scan = app.buttons[Audit.words("Scan QR code")]
    XCTAssertTrue(scan.waitForExistence(timeout: 60), "The signed-out screen didn't show after Sign out.")
    XCTAssertFalse(app.staticTexts["Kite"].exists)
    app.terminate()

    // A relaunch stays signed out.
    let relaunched = Audit.app()
    relaunched.launch()
    XCTAssertTrue(
      relaunched.buttons[Audit.words("Scan QR code")].waitForExistence(timeout: 60), "The relaunch was signed in.")
    relaunched.terminate()
  }
}
