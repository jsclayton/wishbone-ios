/// The user agent that the app and both extensions send: `Wishbone iOS/{version} ({iPhone or iPad})`.
///
/// The server makes a session's name in the Devices list from it. See "Sign-in and devices" in `docs/spec.md`.
public struct UserAgent: Sendable, Equatable {
  public let text: String

  /// `version` is the app's version, such as `1.0`.
  public init(version: String, isPad: Bool) {
    text = "Wishbone iOS/\(version) (\(isPad ? "iPad" : "iPhone"))"
  }
}
