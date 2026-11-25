import TestSupport
import XCTest

/// The first sync fails: the app signs in through the network conditioner, which answers the first sync's
/// `/versions` with a 404. Each screen with no rows shows "Couldn't load your lists from {address}" with Try again,
/// never Loading forever and never an empty state. Once the instance answers again, Try again shows the progress
/// indicator while its sync runs, and then the tabs fill. See "Screens read a local copy" in `docs/spec.md`, and
/// "First sync failed" in `docs/screens/README.md`.
///
/// The conditioner runs in the journey's runner, in the simulator, in front of the shared test server. It audits
/// the error view, and attaches a screenshot of it as evidence for a person.
nonisolated final class FirstSyncFailedJourney: JourneyTestCase {
  @MainActor
  func testFirstSyncFailed() async {
    continueAfterFailure = false
    // XCTest reports an error that a test throws at the place of the last error thrown anywhere, even one that
    // was caught. So the journey catches its own error, and fails with it here.
    do {
      try await firstSyncFailed()
    } catch {
      XCTFail("\(error)")
    }
  }

  @MainActor
  private func firstSyncFailed() async throws {
    let server = try await TestServer.shared()
    let builder = try await FixtureBuilder(server: server)
    // Both birthdays are far off on every date, so Home has nothing in the next 60 days whenever the journey runs.
    let farOff = FixtureBuilder.monthAndDay(daysFromNow: Audit.farOff)
    let robin = try await builder.person("Robin", birthday: farOff)
    // A user who confirmed their profile, so the app shows them no profile gate.
    try await builder.confirmProfile(of: robin)
    let morgan = try await builder.person("Morgan", birthday: farOff, signedIn: false)
    _ = try await builder.group("Family", users: [robin, morgan])

    // The instance refuses the versions: the sign-in works, and its first sync can't finish.
    let conditioner = try await NetworkConditioner(to: server.address)
    defer { conditioner.stop() }
    let versions = NetworkConditioner.Route("GET", "/versions")
    let notFound = try NetworkConditioner.CannedAnswer.problem(404, code: "not_found")
    conditioner.answer(versions, with: notFound)
    let address = conditioner.address.absoluteString
    // In the double-length pseudo-language, iOS doubles the format and fills only one part, so the words read
    // "Couldn't load your lists from @ Couldn't load your lists from {address}". The journey finds them by the words
    // with the address.
    let failedWords = NSPredicate(format: "label CONTAINS %@", "Couldn't load your lists from \(address)")

    // The login link names the conditioner, so the app's instance address is the conditioner's.
    let link = try await conditioner.rerouted(builder.loginLink(for: robin))

    let app = Audit.app()
    app.launchEnvironment["WISHBONE_JOURNEY_START_SIGNED_OUT"] = "1"
    app.launchEnvironment["WISHBONE_JOURNEY_LOGIN_LINK"] = link.absoluteString
    app.launch()

    // Home: the error view with Try again, in place of Loading or People.
    let tryAgain = app.buttons[Audit.words("Try again")]
    XCTAssertTrue(
      app.staticTexts.matching(failedWords).firstMatch.waitForExistence(timeout: 60),
      "Home didn't show the first sync's error view.")
    XCTAssertTrue(tryAgain.exists, "The error view has no Try again.")
    XCTAssertFalse(app.activityIndicators.firstMatch.exists, "The error view shows the progress indicator.")
    XCTAssertFalse(app.buttons[morgan.name].exists, "Home shows People after a first sync that failed.")
    XCTAssertTrue(
      conditioner.requests.contains { $0.isOn(versions) }, "The app's first sync never asked for the versions.")
    try await Audit.run(on: app, showing: "the first sync's error view", in: self)

    // Gifts has nothing saved either: the same view, never its empty state.
    let tabs = app.tabBars.firstMatch
    tabs.buttons[Audit.words("Gifts")].tap()
    XCTAssertTrue(tabs.buttons[Audit.words("Gifts")].isSelected)
    XCTAssertTrue(
      app.staticTexts.matching(failedWords).firstMatch.waitForExistence(timeout: 10),
      "Gifts didn't show the first sync's error view.")
    // The empty words are too long for a query by identifier, so the journey matches them by label.
    let emptyGifts = app.staticTexts.matching(
      NSPredicate(
        format: "label == %@",
        Audit.words("You aren't getting anything yet. Open someone on Home and tap I'll get this."))
    ).firstMatch
    XCTAssertFalse(emptyGifts.exists, "Gifts claims to be empty.")
    tabs.buttons[Audit.words("Home")].tap()
    XCTAssertTrue(tryAgain.waitForExistence(timeout: 10), "Home lost its error view.")

    // The instance answers again. The conditioner holds the next request for the versions before it reaches the
    // server, so Try again's sync waits, and the app's timer can't fill the screen before the tap. While it waits,
    // the screen shows the progress indicator.
    let hold = conditioner.hold(versions, at: .request)
    tryAgain.tap()
    await hold.waitUntilHeld()
    XCTAssertTrue(
      app.activityIndicators.firstMatch.waitForExistence(timeout: 10),
      "Try again doesn't show the progress indicator while its sync runs.")
    XCTAssertFalse(app.staticTexts.matching(failedWords).firstMatch.exists)
    conditioner.passEverything()

    // The tabs fill: Home shows People, and Gifts its empty state, after a sync that succeeded.
    XCTAssertTrue(app.buttons[morgan.name].waitForExistence(timeout: 60), "Home didn't fill after Try again.")
    XCTAssertFalse(app.staticTexts.matching(failedWords).firstMatch.exists, "The error view stayed on Home.")
    tabs.buttons[Audit.words("Gifts")].tap()
    XCTAssertTrue(emptyGifts.waitForExistence(timeout: 30), "Gifts didn't show its empty state after Try again.")
    XCTAssertFalse(app.staticTexts.matching(failedWords).firstMatch.exists, "The error view stayed on Gifts.")
    app.terminate()
  }
}
