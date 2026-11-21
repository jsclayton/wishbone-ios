import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// The two version blocks: the instance is too old, and the app is too old. Each keeps the session. See "Version
/// checks" in `docs/spec.md`, and `docs/screens/version-block.md`.
@Suite("Version blocks", .timeLimit(.minutes(1)))
@MainActor
struct VersionBlockTests {
  typealias Route = NetworkConditioner.Route

  static let health = Route("GET", "/health")
  static let versions = Route("GET", "/versions")
  static let patchMe = Route("PATCH", "/users/me")
  static let redeem = Route("POST", "/login-links/redeem")

  let instance: Instance

  /// The one window of the app, as it comes to the foreground.
  let window = UUID()

  init() async throws {
    instance = try await Instance()
  }

  /// A device signed in as the person, with the titles in its copy.
  private func signedIn(as person: Fixture.Person, expecting titles: [String], timeZone: String = "UTC")
    async throws -> Device
  {
    let device = instance.device(timeZone: .fixed(timeZone))
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    await until { session.primaryListItems.map(\.title) == titles }
    return device
  }

  /// `GET /health` answers with the version, as an instance that runs it does.
  private func instanceRuns(_ version: String) throws {
    instance.conditioner.answer(
      Self.health, with: try .json(200, ["status": "ok", "version": .string(version), "commit": "0ld0ld0"]))
  }

  private func count(_ route: Route) -> Int {
    instance.conditioner.requests.count { $0.isOn(route) }
  }

  @Test("A /health below the minimum at a foreground gives the block, with the version and the minimum")
  func instanceTooOldAtForeground() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let device = try await signedIn(as: robin, expecting: ["Kite"])
    let session = try #require(device.session)
    let kept = try #require(instance.keychain.read())

    try instanceRuns("2.1.9+0ld0ld0")
    let pulls = count(Self.versions)
    await session.cameToForeground(window: window)

    #expect(session.versionBlock == .instanceTooOld(version: "2.1.9", minimum: minimumServerVersion))
    // The session stays, with its copy, and nothing is asked of an instance that the app can't work with.
    #expect(device.session === session)
    #expect(instance.keychain.read() == kept)
    #expect(session.primaryListItems.map(\.title) == ["Kite"])
    #expect(count(Self.versions) == pulls)
    await session.syncNow()
    #expect(count(Self.versions) == pulls)
  }

  @Test("When the check passes again, the block goes by itself, and the session syncs")
  func blockGoesWhenTheCheckPasses() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let list = try await instance.builder.primaryList(of: robin)
    let device = try await signedIn(as: robin, expecting: ["Kite"])
    let session = try #require(device.session)

    try instanceRuns("2.1.9")
    await session.cameToForeground(window: window)
    #expect(session.versionBlock != nil)

    // Try again, with the instance still too old: the block stays.
    let checks = count(Self.health)
    await session.tryVersionCheckAgain()
    #expect(count(Self.health) == checks + 1)
    #expect(session.versionBlock == .instanceTooOld(version: "2.1.9", minimum: minimumServerVersion))

    // The instance is updated. Try again lifts the block, and the sync brings what changed meanwhile.
    _ = try await instance.builder.item("Tent", on: list, as: robin)
    instance.conditioner.passEverything()
    await session.tryVersionCheckAgain()
    #expect(session.versionBlock == nil)
    #expect(session.primaryListItems.map(\.title) == ["Kite", "Tent"])

    // At a foreground, the check lifts it too.
    try instanceRuns("2.1.9")
    await session.cameToForeground(window: window)
    #expect(session.versionBlock != nil)
    instance.conditioner.passEverything()
    await session.cameToForeground(window: window)
    #expect(session.versionBlock == nil)
    #expect(device.session === session)
  }

  @Test("An instance that can't be reached at a foreground changes no block")
  func unreachableCheckKeepsTheBlock() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let device = try await signedIn(as: robin, expecting: ["Kite"])
    let session = try #require(device.session)

    try instanceRuns("2.1.9")
    await session.cameToForeground(window: window)
    instance.conditioner.passEverything()
    instance.conditioner.dropEverything()
    await session.cameToForeground(window: window)
    #expect(session.versionBlock == .instanceTooOld(version: "2.1.9", minimum: minimumServerVersion))

    // With no block, the check that can't reach the instance holds nothing back: the sync says it can't reach it.
    instance.conditioner.passEverything()
    await session.cameToForeground(window: window)
    #expect(session.versionBlock == nil)
    instance.conditioner.dropEverything()
    await session.cameToForeground(window: window)
    #expect(session.versionBlock == nil)
    #expect(session.isInstanceUnreachable)
  }

  @Test("A 404 for the versions runs the version check, which gives the block")
  func versions404RunsTheCheck() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let device = try await signedIn(as: robin, expecting: ["Kite"])
    let session = try #require(device.session)

    // An instance below the minimum has no GET /versions.
    try instanceRuns("2.1.9")
    instance.conditioner.answer(Self.versions, with: try .problem(404, code: "not_found"))
    await session.syncNow()

    #expect(session.versionBlock == .instanceTooOld(version: "2.1.9", minimum: minimumServerVersion))
    #expect(!session.isInstanceUnreachable)
    #expect(device.session === session)
  }

  @Test("A 410 api_version_removed on a sync gives the block for an app that is too old, and the session stays")
  func appTooOldOnSync() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let device = try await signedIn(as: robin, expecting: ["Kite"])
    let session = try #require(device.session)
    let kept = try #require(instance.keychain.read())

    instance.conditioner.answer(Self.versions, with: try .problem(410, code: "api_version_removed"))
    await session.syncNow()

    #expect(session.versionBlock == .appTooOld)
    #expect(device.session === session)
    #expect(instance.keychain.read() == kept)
    #expect(session.primaryListItems.map(\.title) == ["Kite"])

    // Only an update of the app lifts it: a version check that passes does not.
    let pulls = count(Self.versions)
    await session.cameToForeground(window: window)
    #expect(session.versionBlock == .appTooOld)
    #expect(count(Self.versions) == pulls)
  }

  @Test("A 410 api_version_removed on any request gives the block: the report of the time zone")
  func appTooOldOnAnyRequest() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let device = try await signedIn(as: robin, expecting: ["Kite"])
    let session = try #require(device.session)
    #expect(session.versionBlock == nil)

    // The device moves to another zone, so the next foreground reports it.
    let moved = instance.device(timeZone: .fixed("Europe/Paris"))
    let movedSession = try #require(moved.session)
    await movedSession.syncNow()
    instance.conditioner.answer(Self.patchMe, with: try .problem(410, code: "api_version_removed"))
    let reports = count(Self.patchMe)
    await movedSession.cameToForeground(window: window)

    #expect(count(Self.patchMe) == reports + 1)
    #expect(movedSession.versionBlock == .appTooOld)
    #expect(moved.session === movedSession)
  }

  @Test("A 410 that is not the API's own counts as unreachable, and gives no block")
  func other410IsUnreachable() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let device = try await signedIn(as: robin, expecting: ["Kite"])
    let session = try #require(device.session)

    let page = Data("<html><body>Gone</body></html>".utf8)
    instance.conditioner.answer(
      Self.versions, with: .init(status: 410, headers: ["Content-Type": "text/html; charset=utf-8"], body: page))
    await session.syncNow()

    #expect(session.versionBlock == nil)
    #expect(session.isInstanceUnreachable)
    #expect(device.session === session)
  }

  @Test("A version that the app can't read passes at a foreground, and the session syncs")
  func unreadableVersionPasses() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let list = try await instance.builder.primaryList(of: robin)
    let device = try await signedIn(as: robin, expecting: ["Kite"])
    let session = try #require(device.session)

    try instanceRuns("dev")
    _ = try await instance.builder.item("Tent", on: list, as: robin)
    await session.cameToForeground(window: window)

    #expect(session.versionBlock == nil)
    #expect(session.primaryListItems.map(\.title) == ["Kite", "Tent"])
  }

  @Test("During sign-in, the block shows, no redeem is sent, and Back returns to the signed-out screen")
  func instanceTooOldDuringSignIn() async throws {
    let robin = try await instance.person()
    let link = try await instance.loginLink(for: robin)
    try instanceRuns("2.1.9")

    let device = instance.device()
    await device.signIn(pasting: link)

    #expect(
      device.signInState == .instanceTooOld(try instance.address, version: "2.1.9", minimum: minimumServerVersion))
    #expect(count(Self.redeem) == 0)
    #expect(device.session == nil)
    #expect(!device.keepsLink)

    device.cancelSignIn()
    #expect(device.signInState == .plain)
  }

  @Test("A 410 api_version_removed on the redeem gives the block for an app that is too old, with Back")
  func appTooOldDuringSignIn() async throws {
    let robin = try await instance.person()
    let link = try await instance.loginLink(for: robin)
    instance.conditioner.answer(Self.redeem, with: try .problem(410, code: "api_version_removed"))

    let device = instance.device()
    await device.signIn(pasting: link)

    #expect(device.signInState == .appTooOld(try instance.address))
    #expect(device.session == nil)
    #expect(instance.keychain.read() == nil)

    device.cancelSignIn()
    #expect(device.signInState == .plain)
  }

  @Test("Sign out works while a block shows, and the next sign-in starts with no block")
  func signOutFromTheBlock() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let device = try await signedIn(as: robin, expecting: ["Kite"])
    let session = try #require(device.session)

    try instanceRuns("2.1.9")
    await session.cameToForeground(window: window)
    #expect(session.versionBlock != nil)

    await device.signOut()
    #expect(device.session == nil)
    #expect(device.signInState == .plain)
    #expect(instance.keychain.read() == nil)
    #expect(session.versionBlock == nil)
  }
}
