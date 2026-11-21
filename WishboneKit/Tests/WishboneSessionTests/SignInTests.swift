import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// Sign-in with a pasted login link, at the session model's seam, against the real server. See "Sign-in, instances
/// and the session" in `docs/spec.md`.
@Suite("Signing in with a pasted link", .timeLimit(.minutes(1)))
@MainActor
struct SignInTests {
  typealias Route = NetworkConditioner.Route

  let instance: Instance

  init() async throws {
    instance = try await Instance()
  }

  @Test("Signing in with a pasted link publishes the user, and the primary list's item titles from the copy")
  func signsIn() async throws {
    let robin = try await instance.person(items: ["Kite", "Puzzle"])
    let device = instance.device()
    #expect(device.signInState == .plain)
    #expect(device.session == nil)

    await device.signIn(pasting: try await instance.loginLink(for: robin))

    #expect(device.signInState == .signedIn(name: robin.name))
    let session = try #require(device.session)
    await until { session.primaryListItems.map(\.title) == ["Kite", "Puzzle"] }
    #expect(session.user?.id == robin.id)
    #expect(session.user?.name == robin.name)
    #expect(session.primaryList?.name == robin.name)
    #expect(!session.isInstanceUnreachable)

    // The session keychain holds the address, the token, and the user's ID from the redeem answer.
    let kept = try #require(instance.keychain.read())
    #expect(kept.instance == (try instance.address))
    #expect(kept.userID == robin.id)

    // "Signed in as {name}" shows briefly. Then the screen is plain again.
    device.finishWelcome()
    #expect(device.signInState == .plain)
  }

  @Test("A paste of anything else is not a login link, and nothing goes to any address")
  func notALoginLink() async throws {
    let device = instance.device()
    await device.signIn(pasting: "https://example.com/wishlist")
    #expect(device.signInState == .notALoginLink)
    #expect(device.session == nil)
    #expect(instance.conditioner.requests.isEmpty)
  }

  @Test("A paste of anything else while a link is kept keeps that link, for Try again")
  func notALoginLinkKeepsTheKeptLink() async throws {
    let robin = try await instance.person()
    let device = instance.device()
    instance.conditioner.dropEverything()
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    #expect(device.signInState == .unreachable(try instance.address))
    #expect(device.keepsLink)

    await device.signIn(pasting: "https://example.com/wishlist")
    #expect(device.signInState == .notALoginLink)
    #expect(device.keepsLink)

    instance.conditioner.passEverything()
    await device.tryAgain()
    #expect(device.signInState == .signedIn(name: robin.name))
    #expect(!device.keepsLink)
  }

  @Test("A scanned login link signs in as a paste does")
  func scannedLinkSignsIn() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let link = try #require(LoginLink(try await instance.loginLink(for: robin)))
    let device = instance.device()

    await device.signIn(scanned: link)

    #expect(device.signInState == .signedIn(name: robin.name))
    let session = try #require(device.session)
    await until { session.primaryListItems.map(\.title) == ["Kite"] }
    #expect(instance.keychain.read()?.userID == robin.id)
  }

  @Test("A used link gives the used-or-expired state, and no session")
  func usedLink() async throws {
    let robin = try await instance.person()
    let link = try await instance.builder.loginLink(for: robin)
    _ = try await instance.server.redeem(link)

    let device = instance.device()
    await device.signIn(pasting: instance.conditioner.rerouted(link).absoluteString)

    #expect(device.signInState == .linkInvalid)
    #expect(device.session == nil)
    #expect(instance.keychain.read() == nil)
  }

  @Test("A /health below the minimum blocks before redeem, and the link is not used")
  func instanceTooOld() async throws {
    let robin = try await instance.person()
    let link = try await instance.loginLink(for: robin)
    instance.conditioner.answer(
      Route("GET", "/health"), with: try .json(200, ["status": "ok", "version": "2.1.9+0ld0ld0", "commit": "0ld0ld0"]))

    let device = instance.device()
    await device.signIn(pasting: link)

    #expect(
      device.signInState
        == .instanceTooOld(try instance.address, version: "2.1.9", minimum: minimumServerVersion))
    #expect(device.session == nil)
    #expect(!instance.conditioner.requests.contains { $0.isOn(Route("POST", "/login-links/redeem")) })

    // The link still works, so the check used nothing.
    instance.conditioner.passEverything()
    await device.signIn(pasting: link)
    #expect(device.signInState == .signedIn(name: robin.name))
  }

  @Test("A version that the app can't read passes, so a development build of the server doesn't block")
  func unreadableVersionPasses() async throws {
    let robin = try await instance.person()
    instance.conditioner.answer(
      Route("GET", "/health"), with: try .json(200, ["status": "ok", "version": "dev", "commit": "unknown"]))
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    #expect(device.signInState == .signedIn(name: robin.name))
  }

  @Test("An address with no Wishbone gives \"No Wishbone found\"")
  func noWishbone() async throws {
    // The server answers a path that is not the API's with a web page.
    let elsewhere = "\(instance.conditioner.address.absoluteString)/elsewhere"
    let device = instance.device()
    await device.signIn(pasting: "\(elsewhere)/login/abc123")
    #expect(device.signInState == .noWishbone(try #require(InstanceAddress(elsewhere))))

    // Another service can answer /health with JSON of its own.
    instance.conditioner.answer(Route("GET", "/health"), with: try .json(200, ["status": "up"]))
    await device.signIn(pasting: "\(instance.conditioner.address.absoluteString)/login/abc123")
    #expect(device.signInState == .noWishbone(try instance.address))

    #expect(device.session == nil)
    #expect(!instance.conditioner.requests.contains { $0.method == "POST" })
  }

  @Test("Unreachable during sign-in keeps the link, and Try again signs in")
  func unreachableKeepsTheLink() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let link = try await instance.loginLink(for: robin)
    let device = instance.device()

    instance.conditioner.dropEverything()
    await device.signIn(pasting: link)
    #expect(device.signInState == .unreachable(try instance.address))
    #expect(device.session == nil)

    instance.conditioner.passEverything()
    await device.tryAgain()
    #expect(device.signInState == .signedIn(name: robin.name))
    let session = try #require(device.session)
    await until { session.primaryListItems.map(\.title) == ["Kite"] }
  }

  @Test("A 5xx during sign-in is unreachable too")
  func serverErrorIsUnreachable() async throws {
    let robin = try await instance.person()
    let device = instance.device()
    instance.conditioner.answer(Route("POST", "/login-links/redeem"), with: .init(status: 502))
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    #expect(device.signInState == .unreachable(try instance.address))

    instance.conditioner.passEverything()
    await device.tryAgain()
    #expect(device.signInState == .signedIn(name: robin.name))
  }

  @Test("When the redeem answer is lost on the way back, Try again reports a used link")
  func lostAnswer() async throws {
    let robin = try await instance.person()
    let link = try await instance.loginLink(for: robin)
    let device = instance.device()

    let hold = instance.conditioner.hold(Route("POST", "/login-links/redeem"))
    async let signingIn: Void = device.signIn(pasting: link)
    await hold.waitUntilHeld()
    // The server has used the link, and the network goes before the answer arrives.
    instance.conditioner.dropEverything()
    await signingIn
    #expect(device.signInState == .unreachable(try instance.address))

    instance.conditioner.passEverything()
    await device.tryAgain()
    #expect(device.signInState == .linkInvalid)
    #expect(device.session == nil)
    #expect(instance.keychain.read() == nil)
  }

  @Test("Cancel forgets the kept link, and returns to the plain state")
  func cancelForgetsTheLink() async throws {
    let robin = try await instance.person()
    let device = instance.device()
    instance.conditioner.dropEverything()
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    #expect(device.signInState == .unreachable(try instance.address))

    device.cancelSignIn()
    #expect(device.signInState == .plain)

    instance.conditioner.passEverything()
    await device.tryAgain()
    #expect(device.signInState == .plain)
    #expect(device.session == nil)
  }

  @Test("A request that passes its time limit is unreachable, on the injected clock")
  func timeoutIsUnreachable() async throws {
    let robin = try await instance.person()
    let link = try await instance.loginLink(for: robin)
    let clock = TestClock()
    let device = instance.device(clock: clock)

    let hold = instance.conditioner.hold(Route("GET", "/health"))
    async let signingIn: Void = device.signIn(pasting: link)
    await hold.waitUntilHeld()
    await clock.waitForSleepers()
    clock.advance(by: .seconds(3600))
    await signingIn

    #expect(device.signInState == .unreachable(try instance.address))
    hold.release()
  }

  @Test("Redeem carries no Authorization header, and the token goes only to the instance address")
  func tokenGoesOnlyToTheInstance() async throws {
    let robin = try await instance.person(items: ["Kite"])
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    let session = try #require(device.session)
    await until { session.primaryListItems.count == 1 }

    let requests = instance.conditioner.requests
    // The version check, the redeem, the first sync, and the report of the zone. The first sync is the versions,
    // and then one request or more for each kind that the copy holds.
    #expect(
      requests.prefix(3).map { "\($0.method) \($0.target)" } == [
        "GET /api/v2/health", "POST /api/v2/login-links/redeem", "GET /api/v2/versions",
      ])
    #expect(requests.dropFirst(3).dropLast().allSatisfy { $0.method == "GET" })
    #expect(requests.count > 6)
    #expect(requests.last.map { "\($0.method) \($0.target)" } == "PATCH /api/v2/users/me")
    for request in requests {
      #expect(request.headers["user-agent"] == "Wishbone iOS/1.0 (iPhone)")
      let needsNoSession = request.isOn(Route("GET", "/health")) || request.isOn(Route("POST", "/login-links/redeem"))
      if needsNoSession {
        #expect(request.headers["authorization"] == nil, "\(request.method) \(request.target)")
      } else {
        #expect(request.headers["authorization"]?.hasPrefix("Bearer ") == true, "\(request.method) \(request.target)")
      }
    }

    // The instance address answers with a redirect to another address. Nothing follows it there, so the token
    // never leaves the instance address.
    let other = try await NetworkConditioner(to: instance.server.address)
    instance.conditioner.answer(
      Route("GET", "/versions"), with: .init(status: 307, headers: ["Location": other.url("/versions").absoluteString]))
    await session.sync()
    #expect(other.requests.isEmpty)
    #expect(session.isInstanceUnreachable)
    #expect(device.session != nil)
  }
}
