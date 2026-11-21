import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// A fresh install starts signed out, at the device's seam, against the real server. See "A fresh install starts
/// signed out" in `docs/spec.md`.
///
/// The test's keychain outlives the app, as the system's Keychain does. A new install marker stands for a reinstall,
/// which deletes the app group's shared container.
@Suite("A fresh install", .timeLimit(.minutes(1)))
@MainActor
struct ReinstallTests {
  typealias Route = NetworkConditioner.Route

  static let revoke = Route("DELETE", "/users/me/sessions/current")

  let instance: Instance

  init() async throws {
    instance = try await Instance()
  }

  private var revokes: Int {
    instance.conditioner.requests.filter { $0.isOn(Self.revoke) }.count
  }

  private func sessionsFolder(in folder: ScratchDirectory) -> URL {
    folder.url.appending(path: "Sessions")
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

  @Test("Sign-in places the install marker")
  func signInPlacesTheMarker() async throws {
    let robin = try await instance.person()
    let device = instance.device()
    #expect(!instance.marker.isPresent)

    await device.signIn(pasting: try await instance.loginLink(for: robin))

    #expect(device.session != nil)
    #expect(instance.marker.isPresent)
  }

  @Test("A session with no marker is revoked on the server and deleted, and the device starts signed out")
  func leftOverSessionIsRevoked() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let folder = try ScratchDirectory("device")
    _ = try await signedIn(as: robin, in: folder, expecting: ["Kite"])
    let kept = try #require(instance.keychain.read())

    // The app is deleted and installed again: the container is new, and the Keychain item is still there.
    let reinstalled = instance.device(storage: .folder(folder.url), marker: InMemoryInstallMarker())

    #expect(reinstalled.session == nil)
    #expect(reinstalled.signInState == .plain)
    #expect(instance.keychain.read() == nil)
    #expect(!FileManager.default.fileExists(atPath: sessionsFolder(in: folder).path(percentEncoded: false)))
    await reinstalled.launchEnded()
    #expect(revokes == 1)

    // The server has revoked the session: its token works no more, so it is gone from the Devices list.
    let client = APIClient(session: kept, userAgent: UserAgent(version: "1.0", isPad: false))
    await #expect(throws: APIError.unauthorized) { _ = try await client.versions(ifNoneMatch: nil) }
  }

  @Test("With the network dropped, a session with no marker is still deleted")
  func leftOverSessionIsDeletedOffline() async throws {
    let robin = try await instance.person()
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    let kept = try #require(instance.keychain.read())

    instance.conditioner.dropEverything()
    let reinstalled = instance.device(marker: InMemoryInstallMarker())
    await reinstalled.launchEnded()

    #expect(reinstalled.session == nil)
    #expect(reinstalled.signInState == .plain)
    #expect(instance.keychain.read() == nil)
    // The revoke never reached the server, so the session stays in the Devices list. The device keeps no token to
    // try again with, so the next launch asks the instance nothing.
    instance.conditioner.passEverything()
    let next = instance.device(marker: InMemoryInstallMarker())
    await next.launchEnded()
    #expect(next.session == nil)
    #expect(revokes == 0)
    let client = APIClient(session: kept, userAgent: UserAgent(version: "1.0", isPad: false))
    _ = try await client.versions(ifNoneMatch: nil)
  }

  @Test("A marker with no Keychain item starts signed out, and the stale database is removed")
  func markerWithNoItemClearsTheStaleData() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let folder = try ScratchDirectory("device")
    _ = try await signedIn(as: robin, in: folder, expecting: ["Kite"])
    _ = try DatabaseFile(under: folder.url)
    #expect(instance.marker.isPresent)

    // A backup restored onto a new device brings the container and the files, and not the "this device only" item.
    instance.keychain.delete()
    let asked = instance.conditioner.requests.count
    let restored = instance.device(storage: .folder(folder.url))
    await restored.launchEnded()

    #expect(restored.session == nil)
    #expect(restored.signInState == .plain)
    #expect(!FileManager.default.fileExists(atPath: sessionsFolder(in: folder).path(percentEncoded: false)))
    #expect(instance.conditioner.requests.count == asked)
  }

  @Test("A session with its marker stays")
  func sessionWithMarkerStays() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let folder = try ScratchDirectory("device")
    _ = try await signedIn(as: robin, in: folder, expecting: ["Kite"])
    let kept = try #require(instance.keychain.read())

    // A relaunch, or an offloaded app installed again: the container and the item are both still there.
    let relaunched = instance.device(storage: .folder(folder.url))
    await relaunched.launchEnded()

    #expect(relaunched.session?.session == kept)
    #expect(instance.keychain.read() == kept)
    #expect(revokes == 0)
    _ = try DatabaseFile(under: folder.url)
  }
}
