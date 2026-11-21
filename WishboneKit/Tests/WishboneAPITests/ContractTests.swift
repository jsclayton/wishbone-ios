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
    #expect(copy["paths"] != .null)
    // The message names the places that differ. The documents themselves are too long to read in a failure.
    let places = differences(between: copy, and: served)
    #expect(
      places.isEmpty,
      """
      The copy differs from the served document. The first of \(places.count) places:
      \(places.prefix(10).joined(separator: "\n"))
      Run `just server-openapi` to take the copy again.
      """
    )
  }

  /// The places where two JSON values differ, as paths such as `paths./api/v2/health.get.summary`.
  private func differences(between copy: JSON, and served: JSON, at path: String = "") -> [String] {
    switch (copy, served) {
    case (.object(let copy), .object(let served)):
      return Set(copy.keys).union(served.keys).sorted().flatMap { key in
        differences(between: copy[key] ?? .null, and: served[key] ?? .null, at: path.isEmpty ? key : "\(path).\(key)")
      }
    case (.array(let copy), .array(let served)) where copy.count == served.count:
      return zip(copy, served).enumerated().flatMap { index, pair in
        differences(between: pair.0, and: pair.1, at: "\(path)[\(index)]")
      }
    default:
      return copy == served ? [] : [path]
    }
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
