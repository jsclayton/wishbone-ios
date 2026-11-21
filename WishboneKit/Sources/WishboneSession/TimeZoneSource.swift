import Foundation

/// Where the device's time zone comes from: its IANA name, such as `Europe/Paris`. See "Time zone" in
/// `docs/spec.md`.
public struct TimeZoneSource: Sendable {
  /// The IANA name of the device's zone now.
  let identifier: @Sendable () -> String

  public init(_ identifier: @escaping @Sendable () -> String) {
    self.identifier = identifier
  }

  /// The system's zone, as it is at each call. A person who travels gets the new zone at the next foreground.
  public static let system = TimeZoneSource { TimeZone.autoupdatingCurrent.identifier }

  /// One zone that never changes, for tests.
  public static func fixed(_ identifier: String) -> TimeZoneSource {
    TimeZoneSource { identifier }
  }
}
