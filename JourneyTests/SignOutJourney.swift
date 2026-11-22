import TestSupport
import XCTest

/// The sign-out journey: from the tabs, the avatar opens Settings, and Sign out, after its warning, shows the
/// signed-out screen, against a real test server. See "Sign out" in `docs/spec.md`, and "The simulator tier" in
/// `docs/development.md`.
///
/// It audits the Settings sheet, the Reminders screen and Acknowledgements, and attaches a screenshot of each as
/// evidence for a person.
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
    let morgan = try await builder.person("Morgan", signedIn: false)
    _ = try await builder.group("Family", users: [robin, morgan])
    let link = try await builder.loginLink(for: robin).absoluteString
    let address = try XCTUnwrap(link.components(separatedBy: "/login/").first)

    // Signed in, on Home.
    let app = Audit.app()
    app.launchEnvironment["WISHBONE_JOURNEY_START_SIGNED_OUT"] = "1"
    app.launchEnvironment["WISHBONE_JOURNEY_LOGIN_LINK"] = link
    app.launch()
    XCTAssertTrue(app.buttons[morgan.name].waitForExistence(timeout: 60), "Home didn't show after the sign-in.")

    // The avatar, at the top trailing corner, reads "Settings", and opens the Settings sheet.
    let avatar = app.navigationBars[Audit.words("Home")].buttons[Audit.words("Settings")]
    XCTAssertTrue(avatar.waitForExistence(timeout: 10), "Home has no avatar.")
    avatar.tap()
    XCTAssertTrue(
      app.navigationBars[Audit.words("Settings")].waitForExistence(timeout: 10), "The Settings sheet didn't show.")

    // The Signed in block: the name, and the full address with its scheme.
    let signedIn = app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", robin.name, address)
    ).firstMatch
    XCTAssertTrue(signedIn.waitForExistence(timeout: 10), "Settings doesn't show the name and \(address).")
    // The rows under Sign out, which a larger text pushes off. At the largest text size they are below the fold,
    // so the journey scrolls each on the screen there.
    // Support Wishbone shows only on the US storefront, which the simulator may or may not have, so its header, row
    // and footer are in the list only when the row shows.
    let support = [
      "Support Wishbone", "Buy John a coffee", "Wishbone is free and open source. A coffee unlocks nothing in the app.",
    ]
    let showsSupport = app.descendants(matching: .any).matching(
      NSPredicate(format: "label BEGINSWITH %@", Audit.words("Buy John a coffee"))
    ).firstMatch.exists
    let rowsBelow =
      ["Share diagnostics"] + (showsSupport ? support : []) + ["About", "Source code", "Acknowledgements", "Version"]
    // Reminders leaves the screen too, but the journey doesn't scroll to it: the scroll stops with the long help line
    // above it half under the bar, and the audit reports that line with no element, so it can't be told apart.
    try await Audit.run(
      on: app, showing: "Settings", in: self, rowsThatLeaveTheScreen: ["Reminders"] + rowsBelow,
      rowsToScrollTo: rowsBelow)

    // Acknowledgements: the app's own notice, then the license of each package. Back goes to Settings. In the
    // double-length pseudo-language the row can be below the fold, where the list hasn't made it yet.
    let acknowledgements = app.buttons[Audit.words("Acknowledgements")]
    for _ in 0..<5 where !(acknowledgements.exists && acknowledgements.isHittable) {
      app.swipeUp()
    }
    acknowledgements.tap()
    XCTAssertTrue(
      app.navigationBars[Audit.words("Acknowledgements")].waitForExistence(timeout: 10),
      "Acknowledgements didn't show.")
    XCTAssertTrue(
      app.staticTexts[Audit.words("Wishbone uses these open source packages.")].exists,
      "Acknowledgements doesn't say what it lists.")
    try await Audit.run(on: app, showing: "Acknowledgements", in: self)
    app.navigationBars[Audit.words("Acknowledgements")].buttons.firstMatch.tap()
    XCTAssertTrue(
      app.navigationBars[Audit.words("Settings")].waitForExistence(timeout: 10), "Back didn't go to Settings.")

    // Settings is where it was left, so the journey scrolls back to the top if it went down for Acknowledgements.
    let reminders = app.buttons[Audit.words("Reminders")].firstMatch
    for _ in 0..<5 where !(reminders.exists && reminders.isHittable) {
      app.swipeDown()
    }

    // Reminders, pushed inside the sheet. VoiceOver reads Remind me early as one button, with its value, and the
    // audit holds the screen's contrast: the value is drawn in the primary color, not the form's secondary gray.
    reminders.tap()
    XCTAssertTrue(
      app.navigationBars[Audit.words("Reminders")].waitForExistence(timeout: 10), "The Reminders screen didn't show.")
    let early = app.buttons[Audit.words("Remind me early")]
    XCTAssertTrue(early.waitForExistence(timeout: 10), "Reminders has no Remind me early row.")
    XCTAssertEqual(early.value as? String, Audit.words("2 weeks"))
    // The rows under the timing, which a larger text pushes off the screen: Show on Lock Screen with its line, as
    // the simulator gives provisional permission, and the footer. The journey doesn't scroll to them at the largest
    // text size: there the line on 9:00 goes whole under the bar, and the audit reports it with no element, so it
    // can't be told apart.
    try await Audit.run(
      on: app, showing: "Reminders", in: self,
      rowsThatLeaveTheScreen: ["Show on Lock Screen", "Reminders arrive quietly", "A reminder names"])
    app.navigationBars[Audit.words("Reminders")].buttons.firstMatch.tap()
    XCTAssertTrue(
      app.navigationBars[Audit.words("Settings")].waitForExistence(timeout: 10), "Back didn't show Settings.")

    // Sign out, after its warning.
    app.buttons[Audit.words("Sign out")].tap()
    let warning = app.alerts[Audit.words("Sign out?")]
    XCTAssertTrue(warning.waitForExistence(timeout: 10), "Sign out gave no warning.")
    XCTAssertTrue(warning.staticTexts[Audit.words("You need a new login link to sign in again.")].exists)
    warning.buttons[Audit.words("Sign out")].tap()

    // The signed-out screen, with no message: the instance was reached.
    let scan = app.buttons[Audit.words("Scan QR code")]
    XCTAssertTrue(scan.waitForExistence(timeout: 60), "The signed-out screen didn't show after Sign out.")
    XCTAssertFalse(app.buttons[morgan.name].exists)
    app.terminate()

    // A relaunch stays signed out.
    let relaunched = Audit.app()
    relaunched.launch()
    XCTAssertTrue(
      relaunched.buttons[Audit.words("Scan QR code")].waitForExistence(timeout: 60), "The relaunch was signed in.")
    relaunched.terminate()
  }
}
