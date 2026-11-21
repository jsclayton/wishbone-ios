import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// What a screen shows from the copy and the outcome of the syncs: its rows, with the line "Can't reach {address}"
/// while the instance can't be reached, or Loading, Can't reach, or its empty state. See "What every screen shares"
/// in `docs/screens/README.md`, and "Unreachable never ends the session" and "Screens read a local copy" in
/// `docs/spec.md`.
@Suite("What a screen shows", .timeLimit(.minutes(1)))
@MainActor
struct ScreenStateTests {
  typealias Route = NetworkConditioner.Route

  static let versions = Route("GET", "/versions")

  let instance: Instance

  init() async throws {
    instance = try await Instance()
  }

  /// A device signed in as the person. Its first sync has ended.
  private func signedIn(as person: Fixture.Person, clock: any Clock<Duration> = ContinuousClock()) async throws
    -> SessionModel
  {
    let device = instance.device(clock: clock)
    await device.signIn(pasting: try await instance.loginLink(for: person))
    return try #require(device.session)
  }

  /// A device that keeps the session of a sign-in, with nothing saved: a launch whose copy is empty.
  private func keptWithNothingSaved(as person: Fixture.Person) async throws -> SessionModel {
    _ = try await signedIn(as: person)
    let relaunched = instance.device()
    let session = try #require(relaunched.session)
    #expect(session.primaryListItems.isEmpty && session.user == nil, "The copy holds rows.")
    return session
  }

  /// How many times a device has asked for the versions: once for each sync that reached the instance.
  private var pulls: Int {
    instance.conditioner.requests.count { $0.isOn(Self.versions) }
  }

  @Test("A sync with the network dropped publishes \"can't reach\", and the saved rows still read")
  func droppedNetwork() async throws {
    let robin = try await instance.person(items: ["Kite", "Puzzle"])
    let session = try await signedIn(as: robin)
    #expect(session.screenState(hasRows: !session.primaryListItems.isEmpty) == .saved(cantReach: false))

    instance.conditioner.dropEverything()
    #expect(await session.syncNow() == .unreachable)

    #expect(session.isInstanceUnreachable)
    #expect(session.primaryListItems.map(\.title) == ["Kite", "Puzzle"])
    #expect(session.screenState(hasRows: !session.primaryListItems.isEmpty) == .saved(cantReach: true))
  }

  @Test("The next sync that succeeds clears \"can't reach\"")
  func clears() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let session = try await signedIn(as: robin)
    instance.conditioner.dropEverything()
    await session.syncNow()
    #expect(session.screenState(hasRows: true) == .saved(cantReach: true))

    instance.conditioner.passEverything()
    #expect(await session.syncNow() == .succeeded)

    #expect(!session.isInstanceUnreachable)
    #expect(session.screenState(hasRows: !session.primaryListItems.isEmpty) == .saved(cantReach: false))
  }

  @Test("A 5xx, a timeout, and an HTML answer as from a proxy each count as unreachable")
  func unreachableAnswers() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let clock = TestClock()
    let session = try await signedIn(as: robin, clock: clock)

    let html = Data("<html><body>Sign in to the network</body></html>".utf8)
    let answers: [(String, NetworkConditioner.CannedAnswer)] = [
      ("The API's own 5xx", try .problem(503, code: "unavailable")),
      ("A proxy's 502", .init(status: 502, headers: ["Content-Type": "text/html"], body: html)),
      ("A proxy's HTML page", .init(status: 200, headers: ["Content-Type": "text/html"], body: html)),
    ]
    for (name, answer) in answers {
      instance.conditioner.passEverything()
      #expect(await session.syncNow() == .succeeded, "\(name): the sync before it")
      #expect(!session.isInstanceUnreachable)

      instance.conditioner.answer(Self.versions, with: answer)
      #expect(await session.syncNow() == .unreachable, "\(name)")
      #expect(session.isInstanceUnreachable, "\(name)")
      #expect(session.screenState(hasRows: true) == .saved(cantReach: true), "\(name)")
    }

    // A request that passes its time limit, on the injected clock.
    instance.conditioner.passEverything()
    #expect(await session.syncNow() == .succeeded)
    let hold = instance.conditioner.hold(Self.versions)
    async let outcome = session.syncNow()
    await hold.waitUntilHeld()
    await clock.waitForSleepers()
    clock.advance(by: .seconds(3600))
    #expect(await outcome == .unreachable, "A timeout")
    #expect(session.isInstanceUnreachable)
    #expect(session.primaryListItems.map(\.title) == ["Kite"])
    hold.release()
  }

  @Test("Before any sync has finished, nothing saved and no network is \"can't reach\", never \"empty\"")
  func neverEmptyBeforeASync() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let session = try await keptWithNothingSaved(as: robin)
    #expect(session.screenState(hasRows: false) == .loading)

    instance.conditioner.dropEverything()
    #expect(await session.syncNow() == .unreachable)
    #expect(!session.hasSynced)
    #expect(session.screenState(hasRows: !session.primaryListItems.isEmpty) == .cantReach)
    #expect(session.screenState(hasRows: !session.giving.isEmpty) == .cantReach)

    // A sync that succeeded and found nothing: Robin gives no gifts, so Giving is empty.
    instance.conditioner.passEverything()
    #expect(await session.syncNow() == .succeeded)
    #expect(session.hasSynced)
    #expect(session.giving.isEmpty)
    #expect(session.screenState(hasRows: !session.giving.isEmpty) == .empty)
    #expect(session.screenState(hasRows: !session.primaryListItems.isEmpty) == .saved(cantReach: false))
  }

  @Test("During the first sync the state is \"loading\", and rows read as they arrive")
  func loadingDuringTheFirstSync() async throws {
    let robin = try await instance.person(items: ["Kite", "Puzzle"])
    let session = try await keptWithNothingSaved(as: robin)
    #expect(!session.isSyncing)

    // A list's items come after the users, so the hold stops the first sync between them.
    let hold = instance.conditioner.hold(Route("GET", "/lists/{id}/items"), at: .request)
    async let outcome = session.syncNow()
    await hold.waitUntilHeld()

    #expect(session.isSyncing)
    #expect(!session.hasSynced)
    // The user has arrived, and reads at once. The items on the user's list have not.
    await until { session.user != nil }
    #expect(session.screenState(hasRows: session.user != nil) == .saved(cantReach: false))
    #expect(session.primaryListItems.isEmpty)
    #expect(session.screenState(hasRows: !session.primaryListItems.isEmpty) == .loading)

    hold.release()
    #expect(await outcome == .succeeded)
    #expect(!session.isSyncing)
    #expect(session.primaryListItems.map(\.title) == ["Kite", "Puzzle"])
    #expect(session.screenState(hasRows: !session.primaryListItems.isEmpty) == .saved(cantReach: false))
  }

  @Test("Try again, which is Sync now, starts one sync")
  func tryAgain() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let session = try await keptWithNothingSaved(as: robin)
    instance.conditioner.dropEverything()
    await session.syncNow()
    #expect(session.screenState(hasRows: false) == .cantReach)

    instance.conditioner.passEverything()
    let before = pulls
    #expect(await session.syncNow() == .succeeded)
    #expect(pulls == before + 1)
    #expect(session.screenState(hasRows: !session.primaryListItems.isEmpty) == .saved(cantReach: false))
  }

  @Test("After the copy is dropped, the state is \"loading\" or \"can't reach\" again, never \"empty\"")
  func droppedCopy() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let folder = try ScratchDirectory("device")
    do {
      // The device goes at the end of this scope, as the app does when it ends.
      let device = instance.device(storage: .folder(folder.url))
      await device.signIn(pasting: try await instance.loginLink(for: robin))
      let first = try #require(device.session)
      #expect(first.screenState(hasRows: !first.giving.isEmpty) == .empty)
      #expect(first.screenState(hasRows: !first.primaryListItems.isEmpty) == .saved(cantReach: false))
    }

    // Another version of the app left a copy of another schema number, so the open drops it.
    try DatabaseFile(under: folder.url).execute("PRAGMA user_version = 9999")
    instance.conditioner.dropEverything()
    let relaunched = instance.device(storage: .folder(folder.url))
    let session = try #require(relaunched.session)
    #expect(session.primaryListItems.isEmpty)
    #expect(session.screenState(hasRows: !session.giving.isEmpty) == .loading)
    #expect(session.screenState(hasRows: !session.primaryListItems.isEmpty) == .loading)

    await session.syncNow()
    #expect(session.screenState(hasRows: !session.giving.isEmpty) == .cantReach)
    #expect(session.screenState(hasRows: !session.primaryListItems.isEmpty) == .cantReach)

    instance.conditioner.passEverything()
    await session.syncNow()
    #expect(session.screenState(hasRows: !session.giving.isEmpty) == .empty)
    #expect(session.screenState(hasRows: !session.primaryListItems.isEmpty) == .saved(cantReach: false))
  }
}
