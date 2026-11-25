import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// A first sync after sign-in that reaches the instance and is refused: a screen with no rows shows the error state
/// with Try again, never Loading forever, and the app goes on syncing on its schedule. See "Screens read a local
/// copy" and "What the copy holds" in `docs/spec.md`, and "What every screen shares" in `docs/screens/README.md`.
@Suite("A first sync that fails", .timeLimit(.minutes(1)))
@MainActor
struct FirstSyncFailedTests {
  typealias Route = NetworkConditioner.Route

  static let versions = Route("GET", "/versions")

  let instance: Instance

  /// The clock of the timer. Only the test moves it.
  let timer = TestClock()

  /// A window of the app, as it comes to the foreground.
  let window = UUID()

  let diagnostics = RecordingDiagnostics()

  init() async throws {
    instance = try await Instance()
  }

  /// The refusals of the first sync that the error state is for.
  enum Refusal: CaseIterable, Sendable, CustomTestStringConvertible {
    case undecodable
    case notFound
    case forbidden

    var testDescription: String {
      switch self {
      case .undecodable: "An answer that can't be decoded"
      case .notFound: "A stray 404"
      case .forbidden: "Another refusal, a 403"
      }
    }

    var answer: NetworkConditioner.CannedAnswer {
      get throws {
        switch self {
        case .undecodable: try .json(200, ["data": .string("Robin's secret wish"), "next_cursor": .null])
        case .notFound: try .problem(404, code: "not_found")
        case .forbidden: try .problem(403, code: "forbidden")
        }
      }
    }

    /// What diagnostics capture for it: the same as for any other refused sync.
    var faults: [Fault] {
      self == .undecodable ? [.undecodableAnswer(.versions, keyPath: "data")] : []
    }
  }

  /// A device that signs in as the person while the instance answers the versions with the answer. The sign-in
  /// has ended, and its first sync with it.
  private func signedIn(as person: Fixture.Person, answering answer: NetworkConditioner.CannedAnswer) async throws
    -> SessionModel
  {
    instance.conditioner.answer(Self.versions, with: answer)
    let device = instance.device(timerClock: timer, diagnostics: diagnostics)
    await device.signIn(pasting: try await instance.loginLink(for: person))
    return try #require(device.session)
  }

  /// How many times the device has asked for the versions.
  private var pulls: Int {
    instance.conditioner.requests.count { $0.isOn(Self.versions) }
  }

  /// Moves the timer's clock one minute on, once the timer waits, and returns when the timer waits again: its sync
  /// has ended by then.
  private func aMinutePasses() async {
    await timer.waitForSleepers()
    timer.advance(by: .seconds(60))
    await timer.waitForSleepers()
  }

  @Test(
    "A refused first sync shows the error state on a screen with no rows, never Loading or empty",
    arguments: Refusal.allCases)
  func refusedFirstSync(_ refusal: Refusal) async throws {
    let robin = try await instance.person(items: ["Kite"])
    let session = try await signedIn(as: robin, answering: try refusal.answer)

    #expect(session.versionBlock == nil)
    #expect(!session.hasSynced)
    #expect(session.firstSyncFailed)
    #expect(!session.isInstanceUnreachable)
    #expect(session.primaryListItems.isEmpty)
    #expect(session.screenState(hasRows: !session.primaryListItems.isEmpty) == .firstSyncFailed)
    #expect(session.screenState(hasRows: !session.giving.isEmpty) == .firstSyncFailed)
    // The user came before the first sync, at sign-in, so a screen of the user's own shows it.
    #expect(session.screenState(hasRows: session.user != nil) == .saved(cantReach: false))
    // Reported as any refused sync is, and nothing more.
    #expect(diagnostics.faults == refusal.faults)
    #expect(!"\(diagnostics.faults)".contains("secret"))
  }

  @Test("The timer keeps its schedule while the error state shows, and a sync that succeeds fills the screen")
  func timerFills() async throws {
    let robin = try await instance.person(items: ["Kite", "Puzzle"])
    let session = try await signedIn(as: robin, answering: try .problem(404, code: "not_found"))
    await session.cameToForeground(window: window)
    #expect(session.screenState(hasRows: false) == .firstSyncFailed)

    // The timer syncs each minute, and each sync is refused. The state stays, with no Loading between: only Try
    // again shows Loading again.
    let before = pulls
    await aMinutePasses()
    #expect(pulls == before + 1)
    #expect(session.screenState(hasRows: false) == .firstSyncFailed)

    let hold = instance.conditioner.hold(Self.versions, at: .request)
    timer.advance(by: .seconds(60))
    await hold.waitUntilHeld()
    #expect(session.isSyncing)
    #expect(session.screenState(hasRows: false) == .firstSyncFailed)

    // The instance answers again. The timer's sync succeeds, and the screen fills.
    instance.conditioner.passEverything()
    await timer.waitForSleepers()
    await until { session.primaryListItems.map(\.title) == ["Kite", "Puzzle"] }
    #expect(session.hasSynced)
    #expect(!session.firstSyncFailed)
    #expect(session.screenState(hasRows: !session.primaryListItems.isEmpty) == .saved(cantReach: false))
    #expect(session.screenState(hasRows: !session.giving.isEmpty) == .empty)
  }

  @Test("Try again shows Loading while its sync runs, and a sync that succeeds fills the screen")
  func tryAgainFills() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let session = try await signedIn(as: robin, answering: try .problem(404, code: "not_found"))
    #expect(session.screenState(hasRows: false) == .firstSyncFailed)

    // Try again while the instance still refuses: Loading while it runs, then the error state again. The 404 for
    // the versions makes the sync check the version, so the hold there stops the sync before it ends.
    var hold = instance.conditioner.hold(Route("GET", "/health"), at: .request)
    var trying = Task { await session.tryAgain() }
    await hold.waitUntilHeld()
    #expect(session.screenState(hasRows: false) == .loading)
    hold.release()
    #expect(await trying.value == .stopped)
    #expect(session.screenState(hasRows: false) == .firstSyncFailed)

    // Try again once the instance answers: Loading while it runs, then the rows.
    instance.conditioner.passEverything()
    hold = instance.conditioner.hold(Self.versions, at: .request)
    let before = pulls
    trying = Task { await session.tryAgain() }
    await hold.waitUntilHeld()
    #expect(session.screenState(hasRows: false) == .loading)
    hold.release()
    #expect(await trying.value == .succeeded)
    #expect(pulls == before + 1)
    await until { session.primaryListItems.map(\.title) == ["Kite"] }
    #expect(!session.firstSyncFailed)
    #expect(session.screenState(hasRows: !session.primaryListItems.isEmpty) == .saved(cantReach: false))
  }

  @Test("A refusal after a sync succeeded changes nothing: the saved rows show, and an empty screen stays empty")
  func refusalAfterRows() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let device = instance.device(timerClock: timer)
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    let session = try #require(device.session)
    await until { session.primaryListItems.map(\.title) == ["Kite"] }
    #expect(session.hasSynced)

    for refusal in Refusal.allCases {
      instance.conditioner.answer(Self.versions, with: try refusal.answer)
      #expect(await session.syncNow() == .stopped, "\(refusal)")
      #expect(!session.firstSyncFailed, "\(refusal)")
      #expect(session.primaryListItems.map(\.title) == ["Kite"], "\(refusal)")
      #expect(session.screenState(hasRows: !session.primaryListItems.isEmpty) == .saved(cantReach: false))
      #expect(session.screenState(hasRows: !session.giving.isEmpty) == .empty, "\(refusal)")
      instance.conditioner.passEverything()
    }
  }

  @Test("No connection at the first sync gives the unreachable state, not the error state")
  func noConnectionAtTheFirstSync() async throws {
    let robin = try await instance.person(items: ["Kite"])
    // The sign-in passes, and its first sync can't reach the instance: the network goes while the versions wait.
    let device = instance.device(timerClock: timer)
    let link = try await instance.loginLink(for: robin)
    let hold = instance.conditioner.hold(Self.versions, at: .request)
    async let signedIn: Void = device.signIn(pasting: link)
    await hold.waitUntilHeld()
    instance.conditioner.dropEverything()
    hold.release()
    await signedIn
    try await unreachableUntilTryAgain(try #require(device.session))
  }

  @Test("A 5xx at the first sync is unreachable, as every 5xx is: the unreachable state, not the error state")
  func serverErrorAtTheFirstSync() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let session = try await signedIn(as: robin, answering: try .problem(500, code: "internal"))
    try await unreachableUntilTryAgain(session)
    #expect(diagnostics.faults.isEmpty)
  }

  /// Checks that the session shows the unreachable state on a screen with no rows, and that Try again fills the
  /// screen once the instance answers.
  private func unreachableUntilTryAgain(_ session: SessionModel) async throws {
    #expect(session.isInstanceUnreachable)
    #expect(!session.firstSyncFailed)
    #expect(session.screenState(hasRows: false) == .cantReach)

    instance.conditioner.passEverything()
    #expect(await session.tryAgain() == .succeeded)
    await until { session.primaryListItems.map(\.title) == ["Kite"] }
    #expect(session.screenState(hasRows: !session.primaryListItems.isEmpty) == .saved(cantReach: false))
  }

  @Test("A refused first sync followed by one that can't reach the instance gives the unreachable state")
  func refusedThenUnreachable() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let session = try await signedIn(as: robin, answering: try .problem(404, code: "not_found"))
    #expect(session.screenState(hasRows: false) == .firstSyncFailed)

    instance.conditioner.dropEverything()
    #expect(await session.syncNow() == .unreachable)
    #expect(!session.firstSyncFailed)
    #expect(session.screenState(hasRows: false) == .cantReach)
  }

  @Test("A first sync that meets a version block shows the block, not the error state")
  func versionBlock() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let session = try await signedIn(as: robin, answering: try .problem(410, code: "api_version_removed"))
    #expect(session.versionBlock == .appTooOld)
    #expect(!session.firstSyncFailed)
  }
}
