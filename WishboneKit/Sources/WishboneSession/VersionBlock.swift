/// Why the app and the instance can't work together. Each block replaces the whole window and keeps the session.
/// See "Version checks" in `docs/spec.md`, and `docs/screens/version-block.md`.
public enum VersionBlock: Sendable, Equatable {
  /// A request got the API's own 410 `api_version_removed`: this version of the app is too old for the instance.
  case appTooOld

  /// The version check found the instance older than the minimum server version.
  case instanceTooOld(version: String, minimum: String)
}
