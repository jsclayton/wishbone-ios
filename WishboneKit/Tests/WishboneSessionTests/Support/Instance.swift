import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// What a test of the session model starts from: a test server, a network conditioner in front of it, and a device
/// that knows the instance only by the conditioner's address.
///
/// The server is the shared one, unless the test gives a private one. On the shared server, a row for the whole
/// instance that another test makes, such as an occasion for everyone, changes what every user sees. So a test
/// that needs `GET /versions` to answer 304 starts a private server.
@MainActor
struct Instance {
  let server: TestServer
  let conditioner: NetworkConditioner
  let builder: FixtureBuilder

  /// The device's session keychain. A second device with the same one stands for a relaunch.
  let keychain = InMemorySessionKeychain()

  init(server: TestServer? = nil) async throws {
    if let server { self.server = server } else { self.server = try await TestServer.shared() }
    let server = self.server
    conditioner = try await NetworkConditioner(to: server.address)
    builder = try await FixtureBuilder(server: server)
  }

  /// The instance address that the device signs in to: the conditioner's.
  var address: InstanceAddress {
    get throws {
      try #require(InstanceAddress(conditioner.address.absoluteString))
    }
  }

  /// A device as the app's composition root builds it, with the test's keychain. Its time zone is the one given,
  /// so a test never depends on the zone of the Mac that runs it.
  func device(
    storage: SessionStorage = .memory,
    clock: any Clock<Duration> = ContinuousClock(),
    timeZone: TimeZoneSource = .fixed("UTC")
  ) -> Device {
    Device(
      Device.Setup(
        userAgent: UserAgent(version: "1.0", isPad: false), keychain: keychain, storage: storage, clock: clock,
        timeZone: timeZone))
  }

  /// A user with the items on their primary list, in order.
  func person(_ name: String = "Robin", items titles: [String] = []) async throws -> Fixture.Person {
    let person = try await builder.person(name)
    let list = try await builder.primaryList(of: person)
    for title in titles {
      _ = try await builder.item(title, on: list, as: person)
    }
    return person
  }

  /// A new login link for the user, as text to paste. It leads to the instance through the conditioner.
  func loginLink(for person: Fixture.Person) async throws -> String {
    conditioner.rerouted(try await builder.loginLink(for: person)).absoluteString
  }
}
