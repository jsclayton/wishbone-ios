import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// Background app refresh: when iOS lets it, the app runs one sync, through the same action as every other way that
/// a sync starts, and then asks for the next run. The app asks for one each time it goes to the background too. With
/// no session, nothing is asked for. See "When the app syncs" in `docs/spec.md`.
///
/// iOS's scheduler is behind a protocol: these tests record what the session asks of it.
@Suite("Background refresh", .timeLimit(.minutes(1)))
@MainActor
struct BackgroundRefreshTests {
  typealias Route = NetworkConditioner.Route

  static let versions = Route("GET", "/versions")
  static let listItems = Route("GET", "/lists/{id}/items")

  /// The least time that the session asks iOS to wait before the next run.
  static let hour = Duration.seconds(60 * 60)

  let instance: Instance
  let refresh = RecordingRefreshScheduler()
  let diagnostics = RecordingDiagnostics()

  init() async throws {
    instance = try await Instance()
  }

  /// A device signed in as the person, with the test's scheduler and diagnostics. Its first sync has ended.
  private func signedIn(as person: Fixture.Person) async throws -> (device: Device, session: SessionModel) {
    let device = instance.device(refresh: refresh, diagnostics: diagnostics)
    await device.signIn(pasting: try await instance.loginLink(for: person))
    return (device, try #require(device.session))
  }

  /// How many times the device has asked for the versions: once for each sync that reached the instance.
  private func pulls() -> Int {
    instance.conditioner.requests.count { $0.isOn(Self.versions) }
  }

  /// The sync's own breadcrumbs that diagnostics have, after the first `count` breadcrumbs.
  private func syncBreadcrumbs(since count: Int) -> [Breadcrumb] {
    diagnostics.breadcrumbs.dropFirst(count).filter { $0.kind == .syncStarted || $0.kind == .syncEnded }
  }

  @Test("A background run does one sync, which brings what changed, and reports that it succeeded")
  func oneSync() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let list = try await instance.builder.primaryList(of: robin)
    let (device, session) = try await signedIn(as: robin)
    _ = try await instance.builder.item("Tent", on: list, as: robin)

    let before = pulls()
    let mark = diagnostics.breadcrumbs.count
    #expect(await device.refreshInBackground() == .succeeded)

    #expect(pulls() == before + 1)
    await until { session.primaryListItems.map(\.title) == ["Kite", "Tent"] }
    #expect(!session.isInstanceUnreachable)
    // The breadcrumbs of the run's sync: its start and its outcome, and nothing more of it.
    #expect(syncBreadcrumbs(since: mark) == [.syncStarted, .syncEnded(.succeeded)])
    #expect(diagnostics.faults.isEmpty)
  }

  @Test("With the network dropped, a background run reports that it failed, and the copy is as it was")
  func networkDropped() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let (device, session) = try await signedIn(as: robin)
    let kite = try #require(session.primaryListItems.first)
    let own = try robin.signedIn()
    try await own.send("PATCH", "/items/\(kite.id)", json: ["title": "Box kite"]).expecting(200)

    instance.conditioner.dropEverything()
    let mark = diagnostics.breadcrumbs.count
    #expect(await device.refreshInBackground() == .unreachable)

    #expect(session.primaryListItems == [kite])
    #expect(session.isInstanceUnreachable)
    #expect(syncBreadcrumbs(since: mark) == [.syncStarted, .syncEnded(.unreachable)])
    #expect(diagnostics.faults.isEmpty)
  }

  @Test(
    """
    A background run that iOS ends early stops its sync: every row is the old one or the new one, nothing is \
    captured, and the next sync finishes the job
    """
  )
  func endedEarly() async throws {
    let robin = try await instance.person(items: ["Kite", "Puzzle"])
    let list = try await instance.builder.primaryList(of: robin)
    let (device, session) = try await signedIn(as: robin)
    let items = session.primaryListItems
    #expect(items.map(\.title) == ["Kite", "Puzzle"])
    let own = try robin.signedIn()
    let renamed = instance.builder.name("Robyn")
    try await own.send("PATCH", "/users/me", json: ["name": .string(renamed)]).expecting(200)
    try await own.send("PATCH", "/items/\(items[0].id)", json: ["title": "Box kite"]).expecting(200)
    _ = try await instance.builder.item("Bike", on: list, as: robin)

    // The pull has saved the user, and the fetch of the items is on its way when iOS ends the run.
    let hold = instance.conditioner.hold(Self.listItems, at: .request)
    let mark = diagnostics.breadcrumbs.count
    let run = Task { await device.refreshInBackground() }
    await hold.waitUntilHeld()
    run.cancel()
    #expect(await run.value == .stopped)
    hold.release()

    // The user is the new one, and the items are the old ones, each whole.
    await until { session.user?.name == renamed }
    #expect(session.primaryListItems == items)
    #expect(syncBreadcrumbs(since: mark) == [.syncStarted, .syncEnded(.stopped)])
    #expect(diagnostics.faults.isEmpty)
    // The run asked for the next one, as every run does.
    #expect(refresh.calls.last == .request(after: Self.hour))

    // The next sync fetches the rest.
    #expect(await session.syncNow() == .succeeded)
    await until { session.primaryListItems.map(\.title) == ["Box kite", "Puzzle", "Bike"] }
    #expect(session.user?.name == renamed)
  }

  @Test(
    """
    Each background run asks for the next, an hour away at the least, and so does going to the background. With no \
    session, nothing is asked for
    """
  )
  func asksForTheNext() async throws {
    let robin = try await instance.person(items: ["Kite"])

    // Signed out: nothing is asked for, and nothing syncs.
    let device = instance.device(refresh: refresh, diagnostics: diagnostics)
    #expect(device.session == nil)
    device.wentToBackground()
    #expect(await device.refreshInBackground() == .stopped)
    #expect(refresh.requests.isEmpty)
    #expect(pulls() == 0)

    // Signing in asks for nothing: the app is in the foreground.
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    #expect(device.session != nil)
    #expect(refresh.requests.isEmpty)

    device.wentToBackground()
    #expect(refresh.requests == [Self.hour])

    #expect(await device.refreshInBackground() == .succeeded)
    #expect(refresh.requests == [Self.hour, Self.hour])

    // A run that can't reach the instance asks for the next one too.
    instance.conditioner.dropEverything()
    #expect(await device.refreshInBackground() == .unreachable)
    #expect(refresh.requests == [Self.hour, Self.hour, Self.hour])
    #expect(refresh.isPending)
  }

  @Test("Sign-out and the API's own 401 cancel the request that is pending")
  func signOutCancels() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let (device, _) = try await signedIn(as: robin)

    device.wentToBackground()
    #expect(refresh.isPending)
    await device.signOut()
    #expect(device.session == nil)
    #expect(refresh.calls.last == .cancel)

    // Signed in again, the app goes to the background, and another session revokes this one. The next run gets
    // the API's own 401: the device signs out, cancels the request, and asks for no next run.
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    device.wentToBackground()
    #expect(refresh.isPending)
    try await revokeDevice(of: robin)
    #expect(await device.refreshInBackground() == .stopped)
    #expect(device.session == nil)
    #expect(device.signInState == .signedOutByServer(try instance.address))
    #expect(refresh.calls.last == .cancel)
    #expect(!refresh.isPending)
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
