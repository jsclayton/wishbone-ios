/// The session that the device holds: one user on one instance. It is what the session keychain keeps.
///
/// See "Where the session lives" in `docs/spec.md`. The token is a secret, so only this module reads it, and the
/// session's description leaves it out.
public struct Session: Sendable, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
  public let instance: InstanceAddress
  public let userID: String
  let token: String

  public init(instance: InstanceAddress, token: String, userID: String) {
    self.instance = instance
    self.token = token
    self.userID = userID
  }

  enum CodingKeys: String, CodingKey {
    case instance
    case token
    case userID = "user_id"
  }

  public var description: String {
    "the session of user \(userID) on \(instance)"
  }

  public var debugDescription: String {
    description
  }
}
