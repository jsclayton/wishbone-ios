import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// A server or a reverse proxy closes an idle kept connection, and a write that goes on it at that moment is lost
/// before any answer. The client sends a write that is safe to repeat once more, and never one that is not. See
/// "Unreachable never ends the session" in `docs/spec.md`.
@Suite("A write whose connection was lost before its answer", .timeLimit(.minutes(1)))
@MainActor
struct LostConnectionTests {
  typealias Route = NetworkConditioner.Route

  static let patchMe = Route("PATCH", "/users/me")
  static let revoke = Route("DELETE", "/users/me/sessions/current")
  static let redeem = Route("POST", "/login-links/redeem")

  let instance: Instance

  init() async throws {
    instance = try await Instance()
  }

  private func requests(on route: Route) -> [NetworkConditioner.SeenRequest] {
    instance.conditioner.requests.filter { $0.isOn(route) }
  }

  @Test("The time zone report, a PATCH with a key, is sent once more with the same key, and the record has the zone")
  func reportIsSentAgain() async throws {
    let robin = try await instance.person()
    instance.conditioner.loseConnection(Self.patchMe)

    let device = instance.device(timeZone: .fixed("Europe/Paris"))
    await device.signIn(pasting: try await instance.loginLink(for: robin))

    _ = try #require(device.session)
    let reports = requests(on: Self.patchMe)
    #expect(reports.count == 2)
    let key = try #require(reports.first?.headers["idempotency-key"])
    #expect(reports.last?.headers["idempotency-key"] == key)
    #expect(try await robin.signedIn().get("/users/me")["timezone"].string == "Europe/Paris")
  }

  @Test("Sign out, a DELETE, is sent once more: the server revokes the session, and the app doesn't say can't reach")
  func signOutIsSentAgain() async throws {
    let robin = try await instance.person()
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    _ = try #require(device.session)
    let kept = try #require(instance.keychain.read())
    instance.conditioner.loseConnection(Self.revoke)

    await device.signOut()

    #expect(device.signInState == .plain)
    #expect(requests(on: Self.revoke).count == 2)
    let client = APIClient(session: kept, userAgent: UserAgent(version: "1.0", isPad: false))
    await #expect(throws: APIError.unauthorized) { _ = try await client.versions(ifNoneMatch: nil) }
  }

  @Test("A redeem, a POST with no key, is never sent again: sign-in says can't reach, and the link still works")
  func redeemIsNotSentAgain() async throws {
    let robin = try await instance.person()
    instance.conditioner.loseConnection(Self.redeem)

    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: robin))

    #expect(device.signInState == .unreachable(try instance.address))
    #expect(device.session == nil)
    #expect(requests(on: Self.redeem).count == 1)

    // The server never got the redeem, so the kept link signs in on Try again.
    await device.tryAgain()
    #expect(device.session != nil)
    #expect(requests(on: Self.redeem).count == 2)
  }
}
