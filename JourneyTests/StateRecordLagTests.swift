import XCTest

/// Which issues the journeys expect as XCTest's time-out on a lagging record of an app's state. See
/// `waitPastStateRecordLag`. These tests launch no app.
nonisolated final class StateRecordLagTests: JourneyTestCase {
  func testOnlyTerminatesTimeOutOnTheAppsOwnClearedProcessIsALag() {
    // XCTest's words, as a local gate recorded them in ClaimJourney on 2026-11-27.
    XCTAssertTrue(
      Self.isTerminationLag(
        "Failed to terminate com.codemonkeylabs.wishbone:23476: Failed to terminate com.codemonkeylabs.wishbone:0"))
    // Another app, a process that XCTest still has an ID for, and any other failure to terminate, are not.
    XCTAssertFalse(
      Self.isTerminationLag(
        "Failed to terminate com.apple.mobilesafari:27424: Failed to terminate com.apple.mobilesafari:0"))
    XCTAssertFalse(
      Self.isTerminationLag(
        "Failed to terminate com.codemonkeylabs.wishbone:23476: Failed to terminate com.codemonkeylabs.wishbone:23476"))
    XCTAssertFalse(
      Self.isTerminationLag(
        "Failed to terminate com.codemonkeylabs.wishbone:23476: IDE reported an error attempting to terminate"))
    XCTAssertFalse(
      Self.isTerminationLag(
        "Failed to terminate com.codemonkeylabs.wishbone.ShareExtension:23476: "
          + "Failed to terminate com.codemonkeylabs.wishbone.ShareExtension:0"))
  }
}
