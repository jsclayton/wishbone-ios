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

  /// The sign-in again, as a user with no confirmed profile: the profile gate shows before the tabs, and Continue
  /// reaches Home. See `docs/screens/profile-gate.md`.
  @MainActor
  func testSignInToTheProfileGate() async {
    continueAfterFailure = false
    do {
      try await signInToTheProfileGate()
    } catch {
      XCTFail("\(error)")
    }
  }

  @MainActor
  private func signInToTheProfileGate() async throws {
    let server = try await TestServer.shared()
    let builder = try await FixtureBuilder(server: server)
    let sam = try await builder.person("Sam")
    // Someone to give to, so Home shows People.
    let ash = try await builder.person("Ash", signedIn: false)
    _ = try await builder.group("Camp", users: [sam, ash])

    let app = Audit.app()
    app.launchEnvironment["WISHBONE_JOURNEY_START_SIGNED_OUT"] = "1"
    app.launchEnvironment["WISHBONE_JOURNEY_LOGIN_LINK"] = try await builder.loginLink(for: sam).absoluteString
    app.launch()

    // The gate, in place of the tabs, with the profile's name in its field. Its title is the form's first row, and
    // its bar holds Sign out and Continue.
    let title = app.staticTexts[Audit.words("Finish your profile")]
    let gate = app.navigationBars.firstMatch
    XCTAssertTrue(title.waitForExistence(timeout: 60), "The profile gate didn't show after the sign-in.")
    XCTAssertFalse(app.tabBars.firstMatch.exists, "The tabs show behind the profile gate.")
    XCTAssertTrue(app.staticTexts[Audit.words("Check your name and birthday. Your family sees them.")].exists)
    // The name field holds the profile's name.
    let nameField = app.descendants(matching: .any).matching(NSPredicate(format: "value == %@", sam.name)).firstMatch
    XCTAssertTrue(nameField.exists, "The name field doesn't hold the profile's name.")
    XCTAssertTrue([.textField, .textView].contains(nameField.elementType), "The name is not in a field.")
    XCTAssertTrue(app.buttons[Audit.words("Add a photo")].exists, "The gate has no photo control.")
    XCTAssertTrue(gate.buttons[Audit.words("Sign out")].exists, "The gate has no Sign out.")
    XCTAssertTrue(gate.buttons[Audit.words("Continue")].exists, "The gate has no Continue in its bar.")
    try await Audit.run(on: app, showing: "the profile gate", in: self)

    // Continue confirms the profile, and the window shows Home.
    gate.buttons[Audit.words("Continue")].tap()
    XCTAssertTrue(app.buttons[ash.name].waitForExistence(timeout: 60), "Home didn't show after Continue.")
    XCTAssertTrue(app.tabBars.firstMatch.buttons[Audit.words("Home")].isSelected)
    XCTAssertFalse(title.exists)
    app.terminate()

    // A relaunch goes straight to the tabs.
    let relaunched = Audit.app()
    relaunched.launch()
    XCTAssertTrue(relaunched.buttons[ash.name].waitForExistence(timeout: 60), "The relaunch didn't show Home.")
    XCTAssertFalse(relaunched.staticTexts[Audit.words("Finish your profile")].exists)
    relaunched.terminate()
  }

  @MainActor
  private func signIn() async throws {
    let server = try await TestServer.shared()
    let builder = try await FixtureBuilder(server: server)
    // Home's People: Robin's parent, and the people of Robin's group.
    let morgan = try await builder.person("Morgan", signedIn: false)
    let jordan = try await builder.person("Jordan", signedIn: false)
    let robin = try await builder.person("Robin", parents: [morgan])
    _ = try await builder.group("Family", users: [robin, morgan, jordan])
    // A user who confirmed their profile, so the app shows them no profile gate.
    try await builder.confirmProfile(of: robin)

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
      ],
      // At the largest text size, the same rows are below the fold, so the journey scrolls each on the screen.
      rowsToScrollTo: [
        "You use Wishbone in a browser.", "You're signed in to the app on another device.",
        "Nobody in your family runs Wishbone yet.", "Running your own Wishbone",
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
    // largest text size, where the row is below the fold, and the journey scrolls it on the screen.
    try await Audit.run(
      on: app, showing: "the Share diagnostics sheet", in: self, rowsThatLeaveTheScreen: ["Privacy policy"],
      rowsToScrollTo: ["Privacy policy"])
    app.navigationBars.buttons[Audit.words("Done")].tap()
    XCTAssertTrue(scan.waitForExistence(timeout: 10))
    XCTAssertFalse(share.exists, "The Share diagnostics sheet didn't close.")
    app.terminate()

    // The same launch, with a login link passed in as if pasted.
    app.launchEnvironment["WISHBONE_JOURNEY_LOGIN_LINK"] = try await builder.loginLink(for: robin).absoluteString
    app.launch()
    // Home: People, with Your parents and the group. Robin is not among their own people.
    XCTAssertTrue(app.buttons[jordan.name].waitForExistence(timeout: 60), "Home didn't show after the sign-in.")
    XCTAssertTrue(app.navigationBars[Audit.words("Home")].exists)
    let labelled = { (words: String) in
      app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", words))
    }
    XCTAssertTrue(labelled(Audit.words("Your parents")).firstMatch.exists, "Home has no Your parents.")
    XCTAssertTrue(labelled(builder.name("Family")).firstMatch.exists, "Home has no part for the group.")
    // Morgan is in Your parents and in the group, and Jordan only in the group. XCUI can find a person more than
    // once in a part, so the journey counts them against each other.
    let found = { (name: String) in app.buttons.matching(NSPredicate(format: "label == %@", name)).count }
    XCTAssertGreaterThan(found(jordan.name), 0)
    XCTAssertEqual(found(morgan.name), 2 * found(jordan.name), "Morgan isn't in both parts.")
    XCTAssertFalse(app.buttons[robin.name].exists, "Robin is among their own people.")

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
    XCTAssertTrue(app.buttons[jordan.name].waitForExistence(timeout: 10), "Home didn't show again.")
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

    try await instanceGoesAway()
  }

  /// The instance goes away while the app runs: what is saved still shows, under the line "Can't reach {address}".
  /// After a relaunch, a tab with nothing saved shows the unreachable view, with Try again. The instance is a
  /// server of the journey's own, so the shared one stays. See "What every screen shares" in
  /// `docs/screens/README.md`.
  @MainActor
  private func instanceGoesAway() async throws {
    let server = try await TestServer.start()
    let builder = try await FixtureBuilder(server: server)
    let sky = try await builder.person("Sky")
    try await builder.confirmProfile(of: sky)
    let rowan = try await builder.person("Rowan", signedIn: false)
    _ = try await builder.group("Friends", users: [sky, rowan])
    let link = try await builder.loginLink(for: sky)
    let parts = try XCTUnwrap(URLComponents(url: link, resolvingAgainstBaseURL: false))
    let address = "\(parts.scheme ?? "")://\(parts.host ?? "")\(parts.port.map { ":\($0)" } ?? "")"
    // In the double-length pseudo-language, iOS doubles the format and fills only its first part, so the line
    // reads "Can't reach @ Can't reach {address}". The journey finds it by the words with the address.
    let lineWords = NSPredicate(format: "label CONTAINS %@", "Can't reach \(address)")

    let app = Audit.app()
    app.launchEnvironment["WISHBONE_JOURNEY_START_SIGNED_OUT"] = "1"
    app.launchEnvironment["WISHBONE_JOURNEY_LOGIN_LINK"] = link.absoluteString
    app.launch()
    XCTAssertTrue(app.buttons[rowan.name].waitForExistence(timeout: 60), "Home didn't show after the sign-in.")
    XCTAssertFalse(app.staticTexts.matching(lineWords).firstMatch.exists)

    // The instance goes away. A window that comes to the foreground syncs, and finds it gone. The journey never
    // pulls to refresh, which is a swipe.
    server.stop()
    try sendHomeAndBack(app)
    XCTAssertTrue(
      app.staticTexts.matching(lineWords).firstMatch.waitForExistence(timeout: 60), "The line didn't show on Home.")
    XCTAssertTrue(app.buttons[rowan.name].exists, "What is saved went with the instance.")
    try await Audit.run(on: app, showing: "Home, with the line", in: self)
    app.terminate()

    // A relaunch with the instance still gone. Gifts has nothing saved, and no sync has reached the instance in this
    // launch: the unreachable view with Try again, never an empty state.
    let relaunched = Audit.app()
    relaunched.launch()
    XCTAssertTrue(relaunched.buttons[rowan.name].waitForExistence(timeout: 60), "The relaunch didn't show Home.")
    XCTAssertTrue(
      relaunched.staticTexts.matching(lineWords).firstMatch.waitForExistence(timeout: 60),
      "The line didn't show after the relaunch.")
    let tabs = relaunched.tabBars.firstMatch
    tabs.buttons[Audit.words("Gifts")].tap()
    let tryAgain = relaunched.buttons[Audit.words("Try again")]
    XCTAssertTrue(tryAgain.waitForExistence(timeout: 10), "Gifts didn't show the unreachable view.")
    XCTAssertTrue(
      relaunched.staticTexts.matching(lineWords).firstMatch.exists, "The unreachable view doesn't name the instance.")
    // The empty words are too long for a query by identifier, so the journey matches them by label.
    let emptyWords = NSPredicate(
      format: "label == %@", Audit.words("You aren't getting anything yet. Open someone on Home and tap I'll get this.")
    )
    XCTAssertFalse(relaunched.staticTexts.matching(emptyWords).firstMatch.exists, "Gifts claims to be empty.")
    try await Audit.run(on: relaunched, showing: "the unreachable view", in: self)

    // Try again syncs. The instance is still gone, so the view stays, and the app goes on.
    tryAgain.tap()
    XCTAssertTrue(tryAgain.waitForExistence(timeout: 30), "The unreachable view went with the instance still gone.")
    relaunched.terminate()
  }

  /// Sends the app to the Home Screen and back, so its window leaves the foreground and comes back to it.
  @MainActor
  private func sendHomeAndBack(_ app: XCUIApplication) throws {
    XCUIDevice.shared.press(.home)
    let left = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in app.state != .runningForeground }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [left], timeout: 10), .completed, "The app didn't leave the foreground.")
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "The app didn't come back.")
  }
}
