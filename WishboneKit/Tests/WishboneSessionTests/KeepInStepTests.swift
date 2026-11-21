import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// When the app syncs: at each foreground, at each network change, every 60 seconds while a window is in the
/// foreground and the instance answers, and on Sync now. One sync runs at a time. See "When the app syncs" in
/// `docs/spec.md`.
@Suite("Keeping in step", .timeLimit(.minutes(1)))
@MainActor
struct KeepInStepTests {
  typealias Route = NetworkConditioner.Route

  static let versions = Route("GET", "/versions")
  static let health = Route("GET", "/health")

  let instance: Instance

  /// The clock of the timer. Only the test moves it.
  let timer = TestClock()

  /// The device's network. Only the test changes it.
  let network = TestNetwork()

  /// A window of the app, as it comes to the foreground.
  let window = UUID()

  init() async throws {
    instance = try await Instance()
  }

  /// A device signed in as the person, on the instance, with the test's timer and network. Its first sync has ended.
  private func signedIn(
    as person: Fixture.Person, on instance: Instance? = nil, storage: SessionStorage = .memory
  ) async throws -> (device: Device, session: SessionModel) {
    let instance = instance ?? self.instance
    let device = instance.device(storage: storage, timerClock: timer, network: network)
    await device.signIn(pasting: try await instance.loginLink(for: person))
    return (device, try #require(device.session))
  }

  /// How many times the device has asked for the versions: once for each sync that reached the instance.
  private func pulls(on instance: Instance? = nil) -> Int {
    (instance ?? self.instance).conditioner.requests.count { $0.isOn(Self.versions) }
  }

  /// Moves the timer's clock one minute on, once the timer waits, and returns when the timer waits again: its sync
  /// has ended by then.
  private func aMinutePasses() async {
    await timer.waitForSleepers()
    timer.advance(by: .seconds(60))
    await timer.waitForSleepers()
  }

  @Test("Coming to the foreground starts one sync. So does a network change")
  func foregroundAndNetworkChange() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let list = try await instance.builder.primaryList(of: robin)
    let (_, session) = try await signedIn(as: robin)

    var before = pulls()
    await session.cameToForeground(window: window)
    #expect(pulls() == before + 1)

    // Another session adds an item, and the device's network changes. The sync brings the item.
    _ = try await instance.builder.item("Tent", on: list, as: robin)
    before = pulls()
    network.change()
    await until { session.primaryListItems.map(\.title) == ["Kite", "Tent"] }
    // Sync now runs one sync, after the network's sync if that still runs. So the change started one sync.
    await session.syncNow()
    #expect(pulls() == before + 2)
  }

  @Test("With a window in the foreground, a sync runs each 60 seconds of the timer's clock. With none, none runs")
  func everyMinuteInTheForeground() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let list = try await instance.builder.primaryList(of: robin)
    let (_, session) = try await signedIn(as: robin)

    // No window has come to the foreground: the timer doesn't run, minutes pass, and nothing syncs.
    #expect(timer.sleeperCount == 0)
    var before = pulls()
    timer.advance(by: .seconds(60 * 5))
    await session.syncNow()
    #expect(pulls() == before + 1)

    await session.cameToForeground(window: window)
    before = pulls()
    for minute in 1...3 {
      await aMinutePasses()
      #expect(pulls() == before + minute)
    }

    // What changed elsewhere arrives within the minute.
    _ = try await instance.builder.item("Tent", on: list, as: robin)
    await aMinutePasses()
    await until { session.primaryListItems.map(\.title) == ["Kite", "Tent"] }

    // The window leaves the foreground: the timer stops, minutes pass, and nothing syncs.
    session.leftForeground(window: window)
    #expect(timer.sleeperCount == 0)
    before = pulls()
    timer.advance(by: .seconds(60 * 5))
    await session.syncNow()
    #expect(pulls() == before + 1)
  }

  @Test("While the instance is unreachable, the timer is stopped. A network change and a sync that succeeds start it")
  func timerStopsWhileUnreachable() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let (_, session) = try await signedIn(as: robin)
    await session.cameToForeground(window: window)

    // The network goes. The timer's sync finds that the instance can't be reached.
    await timer.waitForSleepers()
    instance.conditioner.dropEverything()
    timer.advance(by: .seconds(60))
    await until { session.isInstanceUnreachable }
    // Sync now runs after the timer's sync. A timer that still ran would wait again by the time it ends.
    #expect(await session.syncNow() == .unreachable)
    #expect(timer.sleeperCount == 0)

    // The network comes back. Minutes pass, and the stopped timer syncs nothing.
    instance.conditioner.passEverything()
    let before = pulls()
    timer.advance(by: .seconds(60 * 5))
    #expect(pulls() == before)

    // The network changes, and its sync reaches the instance. The timer runs again.
    network.change()
    await until { !session.isInstanceUnreachable }
    await timer.waitForSleepers()
    #expect(pulls() == before + 1)
    await aMinutePasses()
    #expect(pulls() == before + 2)
    #expect(!session.isInstanceUnreachable)
  }

  @Test("A quiet minute costs one request: the versions, answered 304")
  func quietMinute() async throws {
    // A server of its own: on the shared one, another test's row for the whole instance changes the versions.
    let instance = try await Instance(server: try await TestServer.start())
    let robin = try await instance.person(items: ["Kite"])
    // The record has the device's zone already, so nothing reports it.
    try await robin.signedIn().send("PATCH", "/users/me", json: ["timezone": "UTC"]).expecting(200)
    let (_, session) = try await signedIn(as: robin, on: instance)
    await session.cameToForeground(window: window)

    await timer.waitForSleepers()
    let mark = instance.conditioner.requests.count
    await aMinutePasses()

    let asked = Array(instance.conditioner.requests.dropFirst(mark))
    #expect(asked.count == 1)
    #expect(asked.first?.isOn(Self.versions) == true)
    let etag = try #require(asked.first?.headers["if-none-match"])
    let answer = try await TestHTTP.send(
      "GET", instance.server.url("/versions"),
      headers: ["Authorization": "Bearer \(try robin.signedIn().token)", "If-None-Match": etag])
    #expect(answer.status == 304)
  }

  @Test("Sync now ends when its sync ends, with its outcome, whether it succeeded or not")
  func syncNowEndsWithItsSync() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let (_, session) = try await signedIn(as: robin)

    instance.conditioner.dropEverything()
    #expect(await session.syncNow() == .unreachable)
    #expect(session.isInstanceUnreachable)

    instance.conditioner.passEverything()
    #expect(await session.syncNow() == .succeeded)
    #expect(!session.isInstanceUnreachable)

    // The instance answers, and refuses: the sync stopped, and the instance can be reached.
    instance.conditioner.answer(Self.versions, with: try .problem(429, code: "rate_limited"))
    #expect(await session.syncNow() == .stopped)
    #expect(!session.isInstanceUnreachable)

    // Sync now asked for during a sync ends when the sync after it ends, with that sync's outcome.
    instance.conditioner.passEverything()
    let hold = instance.conditioner.hold(Self.versions, at: .answer)
    let first = Task { await session.syncNow() }
    await hold.waitUntilHeld()
    let second = Task { await session.syncNow() }
    await Task.yield()
    // The instance refuses the next sync.
    instance.conditioner.answer(Self.versions, with: try .problem(429, code: "rate_limited"))
    hold.release()
    #expect(await first.value == .succeeded)
    #expect(await second.value == .stopped)
  }

  @Test("Three syncs asked for during a sync give one more sync, after it, and never two at once")
  func oneSyncAtATime() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let list = try await instance.builder.primaryList(of: robin)
    let (_, session) = try await signedIn(as: robin)

    let before = pulls()
    let hold = instance.conditioner.hold(Self.versions, at: .answer)
    let first = Task { await session.syncNow() }
    await hold.waitUntilHeld()
    // The instance has answered the first sync's versions. Then another session adds an item.
    _ = try await instance.builder.item("Tent", on: list, as: robin)
    let asked = [Task { await session.syncNow() }, Task { await session.syncNow() }, Task { await session.syncNow() }]
    // The three have asked. While the first sync runs, no other sync has asked the instance for anything.
    await Task.yield()
    #expect(pulls() == before + 1)

    hold.release()
    #expect(await first.value == .succeeded)
    for task in asked {
      #expect(await task.value == .succeeded)
    }
    #expect(pulls() == before + 2)
    // Only the sync after the first could see the new item.
    await until { session.primaryListItems.map(\.title) == ["Kite", "Tent"] }
  }

  /// How a session ends while a sync runs.
  enum Ending: CaseIterable, Sendable {
    /// The person signs out.
    case signOut
    /// Another session revokes this one, and the sync gets the API's own 401.
    case revoked
  }

  @Test(
    "A session that ends during a sync: the sync stops, nothing is written after the clearing, and the timer stops",
    arguments: Ending.allCases)
  func endDuringASync(ending: Ending) async throws {
    let robin = try await instance.person(items: ["Kite"])
    let list = try await instance.builder.primaryList(of: robin)
    let folder = try ScratchDirectory("device")
    let (device, session) = try await signedIn(as: robin, storage: .folder(folder.url))
    await session.cameToForeground(window: window)
    await timer.waitForSleepers()

    // A sync runs, and another waits for it. The instance has a new item for the copy.
    _ = try await instance.builder.item("Tent", on: list, as: robin)
    let hold = instance.conditioner.hold(Self.versions, at: ending == .signOut ? .answer : .request)
    let syncing = Task { await session.syncNow() }
    await hold.waitUntilHeld()
    let waiting = Task { await session.syncNow() }

    switch ending {
    case .signOut:
      await device.signOut()
      #expect(device.signInState == .plain)
      hold.release()
    case .revoked:
      try await revokeDevice(of: robin)
      hold.release()
      await until { device.session == nil }
      #expect(device.signInState == .signedOutByServer(try instance.address))
    }
    #expect(await syncing.value == .stopped)
    #expect(await waiting.value == .stopped)

    // Nothing was written after the clearing: no database file came back, and the session model shows nothing.
    #expect(device.session == nil)
    #expect(!FileManager.default.fileExists(atPath: folder.url.appending(path: "Sessions").path(percentEncoded: false)))
    #expect(session.primaryListItems.isEmpty)

    // Nothing asks the instance for anything again: not the timer, a network change, or Sync now.
    #expect(timer.sleeperCount == 0)
    let asked = instance.conditioner.requests.count
    timer.advance(by: .seconds(60 * 5))
    network.change()
    #expect(await session.syncNow() == .stopped)
    await session.cameToForeground(window: window)
    #expect(instance.conditioner.requests.count == asked)
  }

  @Test("While a version block shows, no sync runs. When it lifts, one runs")
  func noSyncWhileBlocked() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let (_, session) = try await signedIn(as: robin)
    await session.cameToForeground(window: window)
    await timer.waitForSleepers()

    // The instance is too old, and the next foreground finds it.
    instance.conditioner.answer(
      Self.health, with: try .json(200, ["status": "ok", "version": "2.1.9", "commit": "0ld0ld0"]))
    await session.cameToForeground(window: window)
    #expect(session.versionBlock != nil)

    // No sync runs: not the timer, a network change, Sync now, or a foreground.
    let before = pulls()
    timer.advance(by: .seconds(60 * 5))
    network.change()
    #expect(await session.syncNow() == .stopped)
    await session.cameToForeground(window: window)
    #expect(pulls() == before)
    #expect(timer.sleeperCount == 0)

    // The instance is updated, and Try again lifts the block. One sync runs, and the timer runs again.
    instance.conditioner.passEverything()
    await session.tryVersionCheckAgain()
    #expect(session.versionBlock == nil)
    #expect(pulls() == before + 1)
    await aMinutePasses()
    #expect(pulls() == before + 2)
  }

  /// Revokes the device's session from the person's other session, as their Devices list in a browser does.
  private func revokeDevice(of person: Fixture.Person) async throws {
    let other = try person.signedIn()
    let sessions = try await other.all("/users/me/sessions")
    let device = try #require(
      sessions.first { $0["is_current"].bool == false && $0["user_agent"].string?.hasPrefix("Wishbone iOS/") == true })
    let id = try #require(device["id"].string)
    _ = try await other.send("DELETE", "/users/me/sessions/\(id)").expecting(204)
  }
}
