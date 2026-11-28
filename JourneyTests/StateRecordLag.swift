import Synchronization
import XCTest

/// The journeys' wait past XCTest's time-out on its record of an app's state: the named flake "XCTest's record of an
/// app's state lags" in `docs/development.md`. `activate()` and `terminate()` each ask for the app's new state, and
/// then wait at most 60 seconds for XCTest's record of app states to say it. That record, which testmanagerd keeps
/// from a RunningBoard process monitor, can lag behind the app. So a journey expects only that time-out, for this
/// app, and then waits on the same record itself, for `stateRecordTimeout`.
extension JourneyTestCase {
  /// How long a journey waits for XCTest's record of an app's state. On 2026-11-27, in CI run 46046440049
  /// attempt 1, the record came 57 seconds after Safari came to the front, and hadn't come more than 60 seconds after
  /// the app came back. A wait for a state that comes ends when it comes, so a long limit costs a passing run
  /// nothing.
  static let stateRecordTimeout: TimeInterval = 180

  /// The reason that a journey gives `XCTExpectFailure` for the time-out: the flake's name. The gate lets a test
  /// pass with a known issue only with this reason, and only a test that `allowedKnownIssues` in
  /// `scripts/gate/steps.mjs` names.
  static let stateRecordLag = "XCTest's record of an app's state lags"

  /// Ends the journey's app. `terminate()` fails with `Failed to terminate <app>:<pid>: Failed to terminate <app>:0`
  /// when its record still says the app runs 60 seconds after it asked for the end: on 2026-11-27, in a local gate,
  /// `ClaimJourney` found the app on its page 0.1 seconds before `terminate()`, which failed 60.7 seconds after. So
  /// the journey expects only that failure, and then waits for the record to say Not Running.
  @MainActor
  func end(_ app: XCUIApplication, in journey: String) async {
    await waitPastStateRecordLag(
      of: app, "termination", in: journey, until: .notRunning, named: "Not Running", isLag: Self.isTerminationLag
    ) {
      app.terminate()
    }
  }

  /// Runs `call`, an XCTest call that waits on its record of the app's state (the `step`), expecting only an issue
  /// for which `isLag` is true, with `continueAfterFailure` on only around it. When that issue came, it waits on the
  /// record itself until it says `state`, for `stateRecordTimeout`, logs a line with how long the record took, and
  /// tells the settings helper. That line is a sighting of the flake, which the gate shows after the run. Any other
  /// issue in `call` is not expected, so the journey fails, and so does a record that doesn't catch up.
  @MainActor
  func waitPastStateRecordLag(
    of app: XCUIApplication, _ step: String, in journey: String, until state: XCUIApplication.State,
    named stateName: String, isLag: @escaping @Sendable (String) -> Bool, _ call: @escaping () -> Void
  ) async {
    let lagged = Lagged()
    let options = XCTExpectedFailure.Options()
    options.isStrict = false
    options.issueMatcher = { issue in
      guard isLag(issue.compactDescription) else { return false }
      lagged.seen.withLock { $0 = true }
      return true
    }
    let start = Date.now
    continueAfterFailure = true
    XCTExpectFailure(Self.stateRecordLag, options: options, failingBlock: call)
    continueAfterFailure = false
    guard lagged.seen.withLock({ $0 }) else { return }
    let caughtUp = app.wait(for: state, timeout: Self.stateRecordTimeout)
    let seconds = Int(Date.now.timeIntervalSince(start).rounded())
    let record = caughtUp ? "the record said so after \(seconds) s" : "the record didn't say so within \(seconds) s"
    print("XCTest's \(step) of the app timed out on its record of the app's state, in \(journey): \(record).")
    await Audit.reportRetry("\(journey), its \(step): \(record)", at: "state-record-lags")
    XCTAssertTrue(
      caughtUp,
      "XCTest's record of the app's state didn't say \(stateName) within \(Int(Self.stateRecordTimeout)) seconds of "
        + "the \(step).")
  }

  /// Whether an issue is `terminate()`'s time-out on a lagging record of this app's state, as XCTest words it: the
  /// app's process with its ID, then the same process, whose ID XCTest has cleared before it gives up.
  nonisolated static func isTerminationLag(_ description: String) -> Bool {
    description.wholeMatch(
      of: #/Failed to terminate com\.codemonkeylabs\.wishbone:\d+: Failed to terminate com\.codemonkeylabs\.wishbone:0/#
    ) != nil
  }
}

/// Whether the expected time-out came, as the issue matcher saw it.
private final class Lagged: Sendable {
  let seen = Mutex(false)
}
