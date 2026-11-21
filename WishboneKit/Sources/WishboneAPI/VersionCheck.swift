/// A Wishbone version that the app can compare: `2.2.0`, also as `v2.2.0` and as `2.2.0+7773ada`.
public struct ServerVersion: Sendable, Comparable {
  /// The version without what a build adds to it: `2.2.0` for `v2.2.0+7773ada`.
  public let text: String

  private let numbers: [UInt]

  /// A pre-release, such as `2.2.0-rc.1`, comes before its release.
  private let isPreRelease: Bool

  /// Nil for a version that the app can't read, such as `dev`.
  public init?(_ text: String) {
    let version = (text.hasPrefix("v") ? text.dropFirst() : text[...]).prefix { $0 != "+" }
    let parts = version.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    let core = parts[0].split(separator: ".", omittingEmptySubsequences: false)
    let numbers = core.compactMap { UInt($0) }
    guard core.count == 3, numbers.count == 3 else { return nil }
    self.text = String(version)
    self.numbers = numbers
    isPreRelease = parts.count > 1
  }

  public static func < (older: ServerVersion, newer: ServerVersion) -> Bool {
    if older.numbers != newer.numbers { return older.numbers.lexicographicallyPrecedes(newer.numbers) }
    return older.isPreRelease && !newer.isPreRelease
  }

  public static func == (one: ServerVersion, other: ServerVersion) -> Bool {
    one.numbers == other.numbers && one.isPreRelease == other.isPreRelease
  }
}

/// What the version check found. See "Version checks" in `docs/spec.md`.
public enum VersionCheck: Sendable, Equatable {
  /// The instance runs the minimum server version or a newer one, or a version that the app can't read. A
  /// development build of the server reports one of those, and it must not block a contributor.
  case passes

  /// The instance is older than the minimum server version.
  case tooOld(version: String, minimum: String)

  /// The address answered, and not as a Wishbone does. A login link that points somewhere else gives this.
  case noWishbone
}

extension APIClient {
  /// Reads `GET /health`, which needs no token, and compares the instance's version with the minimum server
  /// version. It throws when the instance gave no answer.
  public func checkVersion() async throws(APIError) -> VersionCheck {
    let health: Health
    do {
      health = try await self.health()
    } catch .unreachable(.notTheAPI), .undecodable {
      return .noWishbone
    }
    guard let version = ServerVersion(health.version), let minimum = ServerVersion(minimumServerVersion) else {
      return .passes
    }
    return version < minimum ? .tooOld(version: version.text, minimum: minimum.text) : .passes
  }
}
