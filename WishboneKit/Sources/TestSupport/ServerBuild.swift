import Foundation

/// The pinned test server of a checkout: what the pin file says, and where `just server` builds it.
///
/// See "A real server" in `docs/development.md`. The names here are the ones that `scripts/server/pin.mjs` uses.
public struct ServerBuild: Sendable {
  /// The root folder of the checkout.
  public let checkout: URL

  /// The build of the checkout that holds this file, at `WishboneKit/Sources/TestSupport/ServerBuild.swift`.
  public static let current: ServerBuild = {
    var url = URL(filePath: #filePath)
    for _ in 0..<4 {
      url.deleteLastPathComponent()
    }
    return ServerBuild(checkout: url)
  }()

  public init(checkout: URL) {
    self.checkout = checkout
  }

  /// What the pin file holds.
  public struct Pin: Sendable, Equatable, Decodable {
    public let repository: String

    /// The server's release tag, such as `v2.2.0`.
    public let tag: String

    /// The tag's full commit SHA.
    public let commit: String

    /// The version of the release, such as `2.2.0`.
    public var version: String {
      String(tag.dropFirst())
    }

    /// The version that the built server reports, as the release's image does: `2.2.0+7773ada`.
    public var stampedVersion: String {
      "\(version)+\(commit.prefix(7))"
    }
  }

  public var pinFile: URL {
    checkout.appending(path: "WishboneKit/Server/server-pin.json")
  }

  /// The copy of the pinned server's OpenAPI document.
  public var openAPIFile: URL {
    checkout.appending(path: "WishboneKit/Server/openapi.json")
  }

  public func pin() throws -> Pin {
    try JSONDecoder().decode(Pin.self, from: Data(contentsOf: pinFile))
  }

  /// The built server. A checkout with no built server for its pin is an error, which fails the test that asked.
  /// A test never skips for it.
  public func binary() throws -> URL {
    let pin = try pin()
    let binary = checkout.appending(path: "build/server/\(pin.tag)-\(pin.commit.prefix(7))/wishbone")
    guard FileManager.default.isExecutableFile(atPath: binary.path(percentEncoded: false)) else {
      throw NotBuilt(pin: pin, binary: binary)
    }
    return binary
  }

  public struct NotBuilt: Error, CustomStringConvertible {
    public let pin: Pin
    public let binary: URL

    public var description: String {
      """
      The test server \(pin.tag) is not built: there is no \(binary.path(percentEncoded: false)). \
      Run `just server`, which fetches and builds it. `just test` and `just gate` do that first.
      """
    }
  }
}
