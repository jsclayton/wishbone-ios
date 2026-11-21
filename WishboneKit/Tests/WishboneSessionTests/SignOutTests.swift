import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// Sign out, at the session model's seam, against the real server. See "Sign out" in `docs/spec.md`.
@Suite("Signing out", .timeLimit(.minutes(1)))
@MainActor
struct SignOutTests {
  typealias Route = NetworkConditioner.Route

  static let revoke = Route("DELETE", "/users/me/sessions/current")

  let instance: Instance

  /// The one window of the app, as it comes to the foreground.
  let window = UUID()

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

  private var revokes: Int {
    instance.conditioner.requests.filter { $0.isOn(Self.revoke) }.count
  }

  private func sessionsFolder(in folder: ScratchDirectory) -> URL {
    folder.url.appending(path: "Sessions")
  }

  @Test("Sign out revokes the session on the server, and clears the Keychain item and the database")
  func signsOut() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let folder = try ScratchDirectory("device")
    let device = try await signedIn(as: robin, in: folder, expecting: ["Kite"])
    let kept = try #require(instance.keychain.read())
    _ = try DatabaseFile(under: folder.url)

    await device.signOut()

    #expect(device.session == nil)
    #expect(device.signInState == .plain)
    #expect(!device.isSigningOut)
    #expect(revokes == 1)
    #expect(instance.keychain.read() == nil)
    #expect(!FileManager.default.fileExists(atPath: sessionsFolder(in: folder).path(percentEncoded: false)))

    // The server has revoked the session: its token works no more.
    let client = APIClient(session: kept, userAgent: UserAgent(version: "1.0", isPad: false))
    await #expect(throws: APIError.unauthorized) { _ = try await client.versions(ifNoneMatch: nil) }

    // A relaunch starts signed out.
    #expect(instance.device(storage: .folder(folder.url)).session == nil)
  }

  @Test("With the network dropped, the device is cleared after one try, and the message names the address")
  func signsOutOffline() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let folder = try ScratchDirectory("device")
    let device = try await signedIn(as: robin, in: folder, expecting: ["Kite"])

    // The network goes while the request is on its way, so the server never gets it.
    let hold = instance.conditioner.hold(Self.revoke, at: .request)
    async let signingOut: Void = device.signOut()
    await hold.waitUntilHeld()
    #expect(device.isSigningOut)
    instance.conditioner.dropEverything()
    await signingOut

    #expect(device.session == nil)
    #expect(device.signInState == .signedOutUnreachable(try instance.address))
    #expect(instance.keychain.read() == nil)
    #expect(!FileManager.default.fileExists(atPath: sessionsFolder(in: folder).path(percentEncoded: false)))

    // One try: the device keeps no token to try again with.
    instance.conditioner.passEverything()
    await device.signOut()
    #expect(revokes == 1)

    // A sign-in clears the message.
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    #expect(device.signInState == .signedIn(name: robin.name))
  }

  @Test("A 5xx is unreachable too, and the device is cleared")
  func signsOutOnServerError() async throws {
    let robin = try await instance.person()
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    instance.conditioner.answer(Self.revoke, with: .init(status: 503))

    await device.signOut()

    #expect(device.session == nil)
    #expect(device.signInState == .signedOutUnreachable(try instance.address))
    #expect(instance.keychain.read() == nil)
    #expect(revokes == 1)
  }

  @Test("A session that the server has already revoked signs out with no message")
  func signsOutWhenAlreadyRevoked() async throws {
    let robin = try await instance.person()
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    let kept = try #require(instance.keychain.read())
    try await APIClient(session: kept, userAgent: UserAgent(version: "1.0", isPad: false)).revokeCurrentSession()

    await device.signOut()

    #expect(device.session == nil)
    #expect(device.signInState == .plain)
    #expect(instance.keychain.read() == nil)
  }

  @Test("After a sign-out, a link for another user signs in with a database of its own")
  func anotherUserSignsIn() async throws {
    let robin = try await instance.person("Robin", items: ["Kite"])
    let sam = try await instance.person("Sam", items: ["Tent"])
    let folder = try ScratchDirectory("device")
    let device = try await signedIn(as: robin, in: folder, expecting: ["Kite"])
    let robinsFile = try DatabaseFile(under: folder.url)
    let robinsList = try #require(device.session?.primaryList)

    await device.signOut()
    await device.signIn(pasting: try await instance.loginLink(for: sam))

    #expect(device.signInState == .signedIn(name: sam.name))
    let session = try #require(device.session)
    await until { session.primaryListItems.map(\.title) == ["Tent"] }
    #expect(session.user?.id == sam.id)
    #expect(session.list(id: robinsList.id) == nil)
    #expect(instance.keychain.read()?.userID == sam.id)

    // The device has one database: Sam's, in a folder of its own.
    let samsFile = try DatabaseFile(under: folder.url)
    #expect(samsFile.folder != robinsFile.folder)
  }

  @Test("The signed-out state reaches every window, because all read one session model")
  func everyWindowSignsOut() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    // Two windows read the device's one session model.
    let first = try #require(device.session)
    let second = try #require(device.session)
    #expect(first === second)
    await until { first.primaryListItems.map(\.title) == ["Kite"] && !first.users.isEmpty }

    await device.signOut()

    // Each window sees the device signed out. A screen that still holds the session model shows nothing of it,
    // and a sync of it asks the instance nothing.
    #expect(device.session == nil)
    #expect(first.user == nil)
    #expect(first.primaryList == nil)
    #expect(first.primaryListItems.isEmpty)
    #expect(first.users.isEmpty)
    #expect(first.groups.isEmpty)
    #expect(first.occasions.isEmpty)
    #expect(first.memberships.isEmpty)
    #expect(first.user(id: robin.id) == nil)
    let asked = instance.conditioner.requests.count
    await first.syncNow()
    await first.cameToForeground(window: window)
    #expect(instance.conditioner.requests.count == asked)
  }

  @Test("A sign-out while signed out does nothing, and asks the instance nothing")
  func signOutWhileSignedOut() async throws {
    let device = instance.device()
    await device.signOut()
    #expect(device.signInState == .plain)
    #expect(instance.conditioner.requests.isEmpty)
  }
}
