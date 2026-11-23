import XCTest

/// The journeys' hold on XCTest's time-out of a screenshot. See `Screenshot`. These tests launch no app.
nonisolated final class ScreenshotTests: JourneyTestCase {
  /// XCTest's issue, as it recorded it on CI in run 45072154826.
  private static var timeOut: XCTIssue {
    XCTIssue(
      type: .assertionFailure, compactDescription: "Failed to get screenshot: Timed out while requesting screenshot.")
  }

  func testATimeOutWhileAScreenshotIsTakenIsHeldBackAndNoted() {
    // The issue goes through the test case's own `record`, as XCTest's does. Recorded, it would fail this test.
    let timedOut = Screenshot.catchingTimeOut { self.record(Self.timeOut) }
    XCTAssertTrue(timedOut)
    // The next request starts with no time-out.
    XCTAssertFalse(Screenshot.catchingTimeOut {})
  }

  func testOnlyXCTestsTimeOutIsHeldBackAndOnlyWhileAScreenshotIsTaken() {
    // At any other time, the time-out is recorded as it is.
    XCTAssertFalse(Screenshot.catches(Self.timeOut))
    let other = XCTIssue(type: .assertionFailure, compactDescription: "Failed to get screenshot: no app.")
    let caughtOther = Screenshot.catchingTimeOut {
      XCTAssertFalse(Screenshot.catches(other))
      XCTAssertFalse(Screenshot.catches(XCTIssue(type: .assertionFailure, compactDescription: "XCTAssertTrue failed")))
    }
    XCTAssertFalse(caughtOther, "Another issue is not a time-out of a screenshot.")
    // After a reset, as at the start of each test, no screenshot is being taken.
    _ = Screenshot.catchingTimeOut {
      Screenshot.reset()
      XCTAssertFalse(Screenshot.catches(Self.timeOut))
    }
    XCTAssertTrue(Screenshot.isTimeOut(Self.timeOut))
  }
}
