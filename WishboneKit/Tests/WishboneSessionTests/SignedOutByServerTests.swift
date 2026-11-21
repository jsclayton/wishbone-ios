import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// The API's own 401 signs the device out, and a 401 from anything else never does. See "The API's own 401 signs
/// the device out" and "Unreachable never ends the session" in `docs/spec.md`.
@Suite("Signed out by the server", .timeLimit(.minutes(1)))
@MainActor
struct SignedOutByServerTests {
  typealias Route = NetworkConditioner.Route

  static let versions = Route("GET", "/versions")
  static let patchMe = Route("PATCH", "/users/me")

  let instance: Instance

  init() async throws {
    instance = try await Instance()
  }

  /// A device with its database in the folder, signed in as the person, with the titles in its copy.
  private func signedIn(as person: Fixture.Person, in folder: ScratchDirectory, expecting titles: [String])
    async throws -> Device
  {
    let device = instance.device(storage: .folder(folder.url))
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    await until { session.primaryListItems.map(\.title) == titles }
    return device
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

  private func sessionsFolder(in folder: ScratchDirectory) -> String {
    folder.url.appending(path: "Sessions").path(percentEncoded: false)
  }

  @Test("Another session revokes this one: the next sync signs the device out, says so, and forgets everything")
  func revokedSignsOut() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let folder = try ScratchDirectory("device")
    let device = try await signedIn(as: robin, in: folder, expecting: ["Kite"])
    let session = try #require(device.session)
    _ = try DatabaseFile(under: folder.url)

    try await revokeDevice(of: robin)
    await session.sync()

    #expect(device.session == nil)
    #expect(device.signInState == .signedOutByServer(try instance.address))
    #expect(!device.isSigningOut)
    #expect(instance.keychain.read() == nil)
    #expect(!FileManager.default.fileExists(atPath: sessionsFolder(in: folder)))
    // A screen that still holds the session model shows nothing of it.
    #expect(session.primaryListItems.isEmpty)
    #expect(session.user == nil)

    // A relaunch starts signed out.
    #expect(instance.device(storage: .folder(folder.url)).session == nil)

    // A sign-in clears the message.
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    #expect(device.signInState == .signedIn(name: robin.name))
  }

  @Test("A user whom the admin deactivates is signed out with the same message")
  func deactivatedSignsOut() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let folder = try ScratchDirectory("device")
    let device = try await signedIn(as: robin, in: folder, expecting: ["Kite"])
    let session = try #require(device.session)

    _ = try await instance.builder.deactivate(robin)
    await session.sync()

    #expect(device.session == nil)
    #expect(device.signInState == .signedOutByServer(try instance.address))
    #expect(instance.keychain.read() == nil)
    #expect(!FileManager.default.fileExists(atPath: sessionsFolder(in: folder)))
  }

  @Test("An HTML 401, as from a proxy, keeps the session, and counts as unreachable")
  func proxy401IsUnreachable() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let folder = try ScratchDirectory("device")
    let device = try await signedIn(as: robin, in: folder, expecting: ["Kite"])
    let session = try #require(device.session)
    let kept = try #require(instance.keychain.read())

    let page = Data("<html><body>Sign in to the gateway</body></html>".utf8)
    instance.conditioner.answer(
      Self.versions, with: .init(status: 401, headers: ["Content-Type": "text/html; charset=utf-8"], body: page))
    await session.sync()

    #expect(device.session === session)
    #expect(session.isInstanceUnreachable)
    #expect(device.signInState == .signedIn(name: robin.name))
    #expect(instance.keychain.read() == kept)
    #expect(session.primaryListItems.map(\.title) == ["Kite"])
    _ = try DatabaseFile(under: folder.url)

    // The instance answers again, and the session goes on.
    instance.conditioner.passEverything()
    await session.sync()
    #expect(!session.isInstanceUnreachable)
    #expect(device.session === session)
  }

  @Test("A problem+json 401 with another code keeps the session")
  func otherCode401KeepsSession() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let folder = try ScratchDirectory("device")
    let device = try await signedIn(as: robin, in: folder, expecting: ["Kite"])
    let session = try #require(device.session)
    let kept = try #require(instance.keychain.read())

    instance.conditioner.answer(Self.versions, with: try .problem(401, code: "login_link_invalid"))
    await session.sync()

    #expect(device.session === session)
    #expect(device.signInState == .signedIn(name: robin.name))
    #expect(instance.keychain.read() == kept)
    #expect(session.primaryListItems.map(\.title) == ["Kite"])
    _ = try DatabaseFile(under: folder.url)
  }

  @Test("An answer in flight when the API's own 401 signs the device out is never written, and no file comes back")
  func answerInFlightIsNeverWritten() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let list = try await instance.builder.primaryList(of: robin)
    let folder = try ScratchDirectory("device")
    // The device's zone differs from the record's, so sign-in ends with a report of the zone.
    let device = instance.device(storage: .folder(folder.url), timeZone: .fixed("Europe/Paris"))
    let link = try await instance.loginLink(for: robin)
    let address = try instance.address
    let report = instance.conditioner.hold(Self.patchMe, at: .request)
    async let signingIn: Void = device.signIn(pasting: link)
    await report.waitUntilHeld()
    let session = try #require(device.session)
    await until { session.primaryListItems.map(\.title) == ["Kite"] }

    // A sync is under way, with an answer in flight that has a new item for the copy.
    _ = try await instance.builder.item("Tent", on: list, as: robin)
    let pull = instance.conditioner.hold(Self.versions, at: .answer)
    async let syncing: Void = session.sync()
    await pull.waitUntilHeld()

    // The session is revoked, and the report gets the API's own 401.
    try await revokeDevice(of: robin)
    report.release()
    await until { device.signInState == .signedOutByServer(address) }
    #expect(device.session == nil)
    #expect(instance.keychain.read() == nil)
    #expect(!FileManager.default.fileExists(atPath: sessionsFolder(in: folder)))

    // The pull's answer arrives after the sign-out. Nothing is written, and no database file comes back.
    pull.release()
    await syncing
    await signingIn
    #expect(device.session == nil)
    #expect(device.signInState == .signedOutByServer(address))
    #expect(session.primaryListItems.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: sessionsFolder(in: folder)))
  }
}
