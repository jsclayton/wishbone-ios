import Foundation
import Synchronization
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// The app reports the device's time zone to the user's record, so gifts are revealed at the user's own midnight.
/// See "Time zone" in `docs/spec.md`.
@Suite("Reporting the time zone", .timeLimit(.minutes(1)))
@MainActor
struct TimeZoneTests {
  typealias Route = NetworkConditioner.Route

  static let patchMe = Route("PATCH", "/users/me")

  let instance: Instance

  init() async throws {
    instance = try await Instance()
  }

  /// The zone on the user's record, as the user's own session reads it from the server.
  func recordedZone(of person: Fixture.Person) async throws -> String? {
    try await person.signedIn().get("/users/me")["timezone"].string
  }

  @Test("After sign-in with a device zone that differs, the user's record has the device's zone")
  func reportsAfterSignIn() async throws {
    let robin = try await instance.person()
    #expect(try await recordedZone(of: robin) == nil)

    let device = instance.device(timeZone: .fixed("Europe/Paris"))
    await device.signIn(pasting: try await instance.loginLink(for: robin))

    #expect(device.session != nil)
    #expect(try await recordedZone(of: robin) == "Europe/Paris")
    #expect(instance.conditioner.requests.filter { $0.isOn(Self.patchMe) }.count == 1)
  }

  @Test("With the same zone, no report is sent")
  func sameZoneSendsNothing() async throws {
    let robin = try await instance.person()
    _ = try await robin.signedIn().send("PATCH", "/users/me", json: ["timezone": "America/Denver"]).expecting(200)

    let device = instance.device(timeZone: .fixed("America/Denver"))
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    let session = try #require(device.session)
    await session.cameToForeground()

    #expect(!instance.conditioner.requests.contains { $0.method == "PATCH" })
    #expect(try await recordedZone(of: robin) == "America/Denver")
  }

  @Test("At a foreground, a zone that changed since sign-in is reported, once")
  func reportsAChangeAtForeground() async throws {
    let robin = try await instance.person()
    let zone = Zone("Europe/Paris")
    let device = instance.device(timeZone: TimeZoneSource { zone.name.withLock { $0 } })
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    let session = try #require(device.session)
    #expect(try await recordedZone(of: robin) == "Europe/Paris")

    zone.name.withLock { $0 = "Asia/Tokyo" }
    await session.cameToForeground()
    #expect(try await recordedZone(of: robin) == "Asia/Tokyo")

    await session.cameToForeground()
    #expect(instance.conditioner.requests.filter { $0.isOn(Self.patchMe) }.count == 2)
  }

  @Test("After a relaunch, a sync that fetches nothing still knows the record's zone, and a changed zone is reported")
  func reportsAfterARelaunchWithNothingToFetch() async throws {
    // A server of its own: on the shared one, another test's occasion for everyone changes the versions, and the
    // sync is then no 304.
    let instance = try await Instance(server: try await TestServer.start())
    let robin = try await instance.person()
    let folder = try ScratchDirectory("device")
    do {
      // The device goes at the end of this scope, as the app does when it ends.
      let device = instance.device(storage: .folder(folder.url), timeZone: .fixed("Europe/Paris"))
      await device.signIn(pasting: try await instance.loginLink(for: robin))
      // The report changed the user's record. This sync brings the copy in step with it.
      try await #require(device.session).cameToForeground()
    }
    #expect(try await recordedZone(of: robin) == "Europe/Paris")

    // The person travels, and opens the app again. Nothing changed on the instance.
    let relaunched = instance.device(storage: .folder(folder.url), timeZone: .fixed("Asia/Tokyo"))
    let session = try #require(relaunched.session)
    let mark = instance.conditioner.requests.count
    await session.cameToForeground()

    // The sync is one request, which the instance answers with a 304. So the record's zone comes from the copy.
    let asked = instance.conditioner.requests.dropFirst(mark)
    #expect(asked.map { "\($0.method) \($0.target)" } == ["GET /api/v2/versions", "PATCH /api/v2/users/me"])
    #expect(asked.first?.headers["if-none-match"] != nil)
    #expect(try await recordedZone(of: robin) == "Asia/Tokyo")
  }

  @Test("A dropped report changes nothing and shows nothing, and the next foreground sends it")
  func droppedReportIsSentAtTheNextForeground() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let device = instance.device(timeZone: .fixed("Australia/Sydney"))

    // The report never reaches the server: the network goes while it waits.
    let link = try await instance.loginLink(for: robin)
    let hold = instance.conditioner.hold(Self.patchMe, at: .request)
    async let signingIn: Void = device.signIn(pasting: link)
    await hold.waitUntilHeld()
    instance.conditioner.dropEverything()
    await signingIn

    let session = try #require(device.session)
    #expect(device.signInState == .signedIn(name: robin.name))
    #expect(session.primaryListItems.map(\.title) == ["Kite"])
    #expect(try await recordedZone(of: robin) == nil)

    instance.conditioner.passEverything()
    await session.cameToForeground()
    #expect(try await recordedZone(of: robin) == "Australia/Sydney")
    #expect(!session.isInstanceUnreachable)
  }

  @Test("A refused report changes nothing, and the next foreground tries again")
  func refusedReportIsTriedAgain() async throws {
    let robin = try await instance.person()
    instance.conditioner.answer(Self.patchMe, with: .init(status: 503))
    let device = instance.device(timeZone: .fixed("Europe/Paris"))
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    let session = try #require(device.session)
    #expect(try await recordedZone(of: robin) == nil)

    instance.conditioner.passEverything()
    await session.cameToForeground()
    #expect(try await recordedZone(of: robin) == "Europe/Paris")
  }

  @Test("Only /users/me is ever patched with a zone, never a child's record")
  func onlyTheUsersOwnRecord() async throws {
    let family = try await instance.builder.standardFamily()
    let device = instance.device(timeZone: .fixed("Pacific/Auckland"))
    await device.signIn(pasting: try await instance.loginLink(for: family.parent))
    let session = try #require(device.session)
    await session.cameToForeground()

    let patches = instance.conditioner.requests.filter { $0.method == "PATCH" }
    #expect(!patches.isEmpty)
    #expect(patches.allSatisfy { $0.isOn(Self.patchMe) })
    #expect(try await recordedZone(of: family.parent) == "Pacific/Auckland")
    let child = try await family.parent.signedIn().get("/users/\(family.child.id)")
    #expect(child["timezone"] == .null)
  }
}

/// A device zone that a test can move, as a person who travels does.
private final class Zone: Sendable {
  let name: Mutex<String>

  init(_ name: String) {
    self.name = Mutex(name)
  }
}
