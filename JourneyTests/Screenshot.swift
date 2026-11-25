import Synchronization
import XCTest

/// The test case of a journey. While `Screenshot.take` asks XCTest for a screenshot, it keeps XCTest's own
/// "Timed out while requesting screenshot" out of the test's issues, so `Screenshot.take` can ask again. Every other
/// issue, and that one at any other time, is recorded as it is.
nonisolated class JourneyTestCase: XCTestCase {
  /// Each test starts with no screenshot being taken and no time-out noted, also after a test that an earlier
  /// failure stopped while `Screenshot.take` waited.
  override func setUp() {
    super.setUp()
    Screenshot.reset()
  }

  /// Each test starts in the default settings, also after a test that failed in another setting of the audit. See
  /// `Audit.startInDefaultSettings`.
  override func setUp() async throws {
    try await super.setUp()
    try await Audit.startInDefaultSettings()
  }

  override func record(_ issue: XCTIssue) {
    if Screenshot.catches(issue) { return }
    super.record(issue)
  }

  /// How long a journey waits for the app to leave the foreground, and to come back to it. On 2026-11-23, in CI run
  /// 45187683978 attempt 2, the app was still in the foreground 10 seconds after the press of the Home button, on a
  /// slow runner. A wait for a state that comes ends when it comes, so a long limit costs a passing run nothing.
  static let foregroundTimeout: TimeInterval = 60

  /// Sends the app to the Home Screen and back, so its window leaves the foreground and comes back to it. The app
  /// gives up the system keyboard when it leaves the foreground.
  @MainActor
  func sendHomeAndBack(_ app: XCUIApplication) {
    XCUIDevice.shared.press(.home)
    let left = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in app.state != .runningForeground }, object: nil)
    XCTAssertEqual(
      XCTWaiter.wait(for: [left], timeout: Self.foregroundTimeout), .completed, "The app didn't leave the foreground.")
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: Self.foregroundTimeout), "The app didn't come back.")
  }
}

/// The screenshots that a journey reads, with the named flake "XCTest doesn't get a screenshot on a CI runner" in
/// `docs/development.md`.
///
/// On 2026-11-22, in CI run 45072154826, XCTest's request for a screenshot of the Add screen waited about 130
/// seconds, and then failed with `Failed to get screenshot: Timed out while requesting screenshot.` The app was idle
/// all through it: a spindump of the whole runner, which XCTest took about 40 seconds into the wait, shows the app's
/// main thread in its run loop. The same spindump shows macOS's `DumpGPURestart`, started about 33 seconds before it:
/// the runner's GPU had restarted, and the simulator draws its screen with that GPU. The screen recording got no
/// frame for 38 seconds, and stopped about 70 seconds before the test's end. The next journey passed. So the stall
/// is the runner's, not the app's or the journey's.
///
/// XCTest records the time-out as an issue, which `XCUIScreen` doesn't let a test catch. So the journey's test case
/// (`JourneyTestCase`) holds it back while `take` waits, and `take` asks again, at most `retryLimit` times, after
/// `retryPause`. The screenshot of a request that timed out is not read.
nonisolated enum Screenshot {
  /// How many times a screenshot that timed out is asked for again, after the first time.
  static let retryLimit = 2

  /// How long the journey waits before it asks again. A restart of the GPU took about 30 seconds on CI, and
  /// XCTest's own wait is longer than that, so a short pause is enough.
  static let retryPause: Duration = .seconds(5)

  /// XCTest's words for a screenshot that it asked for and didn't get in time.
  static let timeOutWords = "Failed to get screenshot: Timed out"

  private struct State {
    var isTaking = false
    var timedOut = false
  }

  private static let state = Mutex(State())

  /// Whether the issue is XCTest's time-out of a screenshot.
  static func isTimeOut(_ issue: XCTIssue) -> Bool {
    issue.compactDescription.hasPrefix(timeOutWords)
  }

  /// Whether `JourneyTestCase` keeps the issue back: only XCTest's time-out of a screenshot, and only while `take`
  /// waits for one. It notes the time-out for `take`.
  static func catches(_ issue: XCTIssue) -> Bool {
    state.withLock { state in
      guard state.isTaking, isTimeOut(issue) else { return false }
      state.timedOut = true
      return true
    }
  }

  /// Clears the state: no screenshot is being taken, and no time-out is noted. See `JourneyTestCase.setUp()`.
  static func reset() {
    state.withLock { $0 = State() }
  }

  /// Runs `request` as `take` runs a request for a screenshot, and says whether XCTest timed out in it. A test
  /// of the mechanism records an issue in it, as XCTest does.
  static func catchingTimeOut(_ request: () -> Void) -> Bool {
    state.withLock { $0 = State(isTaking: true) }
    defer { state.withLock { $0 = State() } }
    request()
    return state.withLock { $0.timedOut }
  }

  /// A screenshot of the app, and how many requests for it timed out before it. `shown` names what the screen
  /// shows, such as `Home, in dark mode`, for the log and the gate's line.
  ///
  /// A request that times out is asked again, at most `retryLimit` times. Each time is reported to the settings
  /// helper, when the run has one, so the gate's line after the run names it. The time-out after the last try fails
  /// the journey with the words of XCTest.
  @MainActor
  static func take(of app: XCUIApplication, showing shown: String) async throws -> (
    screenshot: XCUIScreenshot, timeOuts: Int
  ) {
    var timeOuts = 0
    while true {
      var screenshot: XCUIScreenshot?
      let timedOut = catchingTimeOut { screenshot = app.screenshot() }
      if !timedOut, let screenshot { return (screenshot, timeOuts) }
      timeOuts += 1
      guard timeOuts <= retryLimit else {
        throw AuditError(
          "XCTest didn't get a screenshot of \(shown), \(timeOuts) times in a row: \(timeOutWords) while requesting screenshot."
        )
      }
      print("XCTest didn't get a screenshot of \(shown) in time. It asks again (\(timeOuts) of \(retryLimit)).")
      await reportRetry(shown)
      try await Task.sleep(for: retryPause)
    }
  }

  /// Tells the settings helper that a screenshot was asked for again, so the gate's line names the flake. A run with
  /// no helper has only the line in the log. A report that doesn't arrive is not a failure: the retry is in the log.
  @MainActor
  private static func reportRetry(_ shown: String) async {
    guard let helper = Audit.helper else { return }
    var request = URLRequest(url: helper.appending(path: "screenshot-retries"))
    request.httpMethod = "POST"
    request.httpBody = Data(shown.utf8)
    request.timeoutInterval = 10
    _ = try? await URLSession.shared.data(for: request)
  }
}
