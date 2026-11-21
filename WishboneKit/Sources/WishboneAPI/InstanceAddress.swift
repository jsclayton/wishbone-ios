import Foundation

/// The instance address: the address of the instance that the app talks to. See `GLOSSARY.md`.
///
/// The app takes it from a login link: it is all the text before `/login/`, with the scheme, the host, the port,
/// and any path. Any `http` or `https` address is accepted, on any port, with any path (see ADR 0011).
public struct InstanceAddress: Sendable, Hashable, CustomStringConvertible {
  /// The address as the login link gave it, such as `https://wishbone.example` or `http://10.0.0.5:8080/family`.
  public let text: String

  /// Nil for a text that is not an `http` or `https` address with a host.
  public init?(_ text: String) {
    guard let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
      scheme == "http" || scheme == "https", let host = parts.host, !host.isEmpty, parts.query == nil,
      parts.fragment == nil
    else { return nil }
    self.text = text
  }

  public var description: String {
    text
  }

  /// The path that every API route is under.
  static let apiPrefix = "/api/v2"

  /// The URL of a path under the instance's `/api/v2`, such as `/lists/7/items`, with a query.
  func url(path: String, query: [URLQueryItem] = []) -> URL? {
    guard var parts = URLComponents(string: text + Self.apiPrefix + path) else { return nil }
    if !query.isEmpty { parts.queryItems = query }
    return parts.url
  }
}

extension InstanceAddress: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    guard let address = InstanceAddress(try container.decode(String.self)) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an instance address.")
    }
    self = address
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(text)
  }
}
