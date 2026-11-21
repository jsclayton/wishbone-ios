import TestSupport
import XCTest

/// The sign-in journey: the app, launched with a login link as if pasted, reaches the screen behind the signed-out
/// screen, against a real test server. See "The simulator tier" in `docs/development.md`.
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
    XCTAssertTrue(app.staticTexts["Kite"].waitForExistence(timeout: 60), "The list didn't show after the sign-in.")
    XCTAssertTrue(app.staticTexts["Puzzle"].exists)
    XCTAssertTrue(app.navigationBars[robin.name].exists)
    try await Audit.run(on: app, showing: "the list after the sign-in", in: self)
    app.terminate()
  }
}
