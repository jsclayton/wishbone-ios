import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// The two sign-in failures that say why: too many tries, and a certificate that the device doesn't trust. See
/// "States" in `docs/screens/signed-out.md`, and "Unreachable never ends the session" in `docs/spec.md`.
@Suite("A sign-in that fails, and says why", .timeLimit(.minutes(1)))
@MainActor
struct SignInFailureTests {
  /// A private server that allows three redeems a minute from one address. The admin's setup and sign-in use two
  /// of them.
  private func instanceWithALowLimit() async throws -> Instance {
    try await Instance(server: try await TestServer.start(environment: ["WISHBONE_RATE_LIMIT_REDEEM": "3"]))
  }

  /// Redeems made-up links at the server until it refuses one for too many tries.
  private func useUpTheLimit(of instance: Instance) async throws {
    for _ in 0..<10 {
      let answer = try await TestHTTP.send(
        "POST", instance.server.url("/login-links/redeem"), json: ["token": "made-up", "session": "bearer"])
      if answer.status == 429 { return }
      try #require(answer.status == 401)
    }
    Issue.record("The server never refused a redeem for too many tries")
  }

  @Test("A redeem over the limit gives the too-many-tries state, and the link is kept for Try again")
  func tooManyTriesKeepsTheLink() async throws {
    let instance = try await instanceWithALowLimit()
    let robin = try await instance.person()
    let link = try await instance.loginLink(for: robin)
    try await useUpTheLimit(of: instance)

    let device = instance.device()
    await device.signIn(pasting: link)
    #expect(device.signInState == .tooManyTries)
    #expect(device.keepsLink)
    #expect(device.session == nil)
    #expect(instance.keychain.read() == nil)

    // Still over the limit: Try again sends the same link, and the state and the link stay.
    let redeem = NetworkConditioner.Route("POST", "/login-links/redeem")
    let redeems = instance.conditioner.requests.count { $0.isOn(redeem) }
    await device.tryAgain()
    #expect(instance.conditioner.requests.count { $0.isOn(redeem) } == redeems + 1)
    #expect(device.signInState == .tooManyTries)
    #expect(device.keepsLink)
  }

  @Test("Cancel after too many tries forgets the link, and returns to the plain state")
  func cancelAfterTooManyTries() async throws {
    let instance = try await instanceWithALowLimit()
    let robin = try await instance.person()
    try await useUpTheLimit(of: instance)

    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    #expect(device.signInState == .tooManyTries)

    device.cancelSignIn()
    #expect(device.signInState == .plain)
    #expect(!device.keepsLink)

    let requests = instance.conditioner.requests.count
    await device.tryAgain()
    #expect(device.signInState == .plain)
    #expect(instance.conditioner.requests.count == requests)
  }

  @Test("A certificate that the device doesn't trust gives its own state, never \"Can't reach\", and no Try again")
  func untrustedCertificate() async throws {
    let instance = try await Instance(tls: .untrustedCertificate)
    let robin = try await instance.person()
    let link = try await instance.loginLink(for: robin)
    #expect(link.hasPrefix("https://"))

    let device = instance.device()
    await device.signIn(pasting: link)
    #expect(device.signInState == .certificateNotTrusted(try instance.address))
    #expect(!device.keepsLink)
    #expect(device.session == nil)
    // The handshake failed, so no request reached the conditioner.
    #expect(instance.conditioner.requests.isEmpty)
  }
}
