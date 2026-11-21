import Foundation

/// A section of Settings. See "Content" in `docs/screens/settings.md`.
///
/// The cases are in the order that Settings shows them. A section joins with the screen of its first row: Your
/// profile, Reminders, Delete account, For the admin, and Support Wishbone are not built yet, and each takes its
/// place in this order when it comes.
public enum SettingsSection: Hashable, Sendable, CaseIterable {
  /// The user's name, the instance address, and Sign out.
  case signedIn

  /// The section that holds Sign-in and devices. Its footer is the help line on Require Face ID. Until the rows of
  /// Sign-in and devices come, it holds only the help line.
  case signInAndDevices

  /// Share diagnostics.
  case shareDiagnostics

  /// Source code, Acknowledgements, and the app's version and build.
  case about

  /// The sections that Settings shows, in order, to a user who is the admin or not, and who has parents or not: the
  /// server's meaning of a child. Every user sees the same sections, until For the admin, which only the admin sees,
  /// and Support Wishbone, which a child never sees, are built.
  public static func shown(isAdmin: Bool, hasParents: Bool) -> [SettingsSection] {
    allCases
  }
}

/// What the About section shows: the app's own address, version, and build, from the app's `Info.plist`.
public struct AppAbout: Equatable, Sendable {
  /// The app's repository, from the build's `WISHBONE_SOURCE_URL`. `nil` when the build has none, and then there is
  /// no Source code row.
  public let sourceCode: URL?

  /// The app's version, such as "1.0".
  public let version: String

  /// The build number.
  public let build: String

  /// The values of an `Info.plist`.
  public init(info: [String: Any]) {
    sourceCode = Self.webAddress(info["WishboneSourceURL"])
    version = info["CFBundleShortVersionString"] as? String ?? ""
    build = info["CFBundleVersion"] as? String ?? ""
  }

  /// The app's own values.
  public static let current = AppAbout(info: Bundle.main.infoDictionary ?? [:])

  /// A web address, or `nil` for anything else: a row that is a web link opens only `https` or `http`.
  private static func webAddress(_ value: Any?) -> URL? {
    guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
      let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
      url.host() != nil
    else { return nil }
    return url
  }
}
