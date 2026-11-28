import TestSupport
import Testing

@Suite("TestClock", .timeLimit(.minutes(1)))
struct TestClockTests {
  @Test("A wait for sleepers returns when a sleeper waits, and when its task is cancelled")
  func waitForSleepers() async throws {
    let clock = TestClock()

    // No sleeper ever comes: the cancel ends the wait, as a test's time limit does.
    let waiting = Task { await clock.waitForSleepers() }
    waiting.cancel()
    await waiting.value

    // A sleeper comes: the wait returns, and the advance wakes it.
    let waitingForOne = Task { await clock.waitForSleepers() }
    let sleeping = Task { try await clock.sleep(for: .seconds(60)) }
    await waitingForOne.value
    #expect(clock.sleeperCount == 1)
    clock.advance(by: .seconds(60))
    try await sleeping.value
    #expect(clock.sleeperCount == 0)
  }
}
