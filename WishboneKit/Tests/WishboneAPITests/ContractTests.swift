import Foundation
import TestSupport
import Testing
import WishboneAPI

/// The pinned test server, the copy of its OpenAPI document, and the minimum server version are one thing in
/// three places. They change together, in one commit. See ADR 0004 and ADR 0007.
@Suite("The contract with the pinned server", .timeLimit(.minutes(1)))
struct ContractTests {
  @Test("The copy is the OpenAPI document that the pinned server serves")
  func copyIsTheServedDocument() async throws {
    let server = try await TestServer.shared()
    let served = try await TestHTTP.send("GET", server.url("/openapi")).expecting(200).json
    let copy = try JSON(parsing: Data(contentsOf: ServerBuild.current.openAPIFile))
    #expect(copy["paths"] == served["paths"])
    #expect(copy["components"] == served["components"])
    #expect(copy == served, "Run `just server-openapi` to take the copy again.")
  }

  @Test("The pinned server reports the minimum server version")
  func pinnedServerReportsTheMinimum() async throws {
    let pin = try ServerBuild.current.pin()
    #expect(pin.version == minimumServerVersion)

    let server = try await TestServer.shared()
    let health = try await TestHTTP.send("GET", server.url("/health")).expecting(200).json
    // The part after `+` is the build's commit, as in the release's image.
    #expect(health["version"].string == pin.stampedVersion)
    #expect(health["version"].string?.split(separator: "+").first.map(String.init) == minimumServerVersion)
  }
}
