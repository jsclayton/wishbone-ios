import Foundation

/// A section of Settings. See "Content" in `docs/screens/settings.md`.
///
/// The cases are in the order that Settings shows them. A section joins with the screen of its first row: Your
/// profile is not built yet, and takes its place in this order when it comes.
public enum SettingsSection: Hashable, Sendable, CaseIterable {
  /// The user's name, the instance address, and Sign out.
  case signedIn

  /// The section that holds Sign-in and devices. Its footer is the help line on Require Face ID. Until the rows of
  /// Sign-in and devices come, it holds only the help line.
  case signInAndDevices

  /// Reminders, which pushes the Reminders screen.
  case reminders

  /// Share diagnostics.
  case shareDiagnostics

  /// For the admin: Blocked stores, with the footer on the jobs that are done on the server. Only the admin sees it.
  case forTheAdmin

  /// Support Wishbone: the one row that opens the maker's support page. See "Support Wishbone" in `docs/spec.md`.
  case supportWishbone

  /// Source code, Acknowledgements, and the app's version and build.
  case about

  /// The sections that Settings shows, in order, to a user who is the admin or not, and who has parents or not: the
  /// server's meaning of a child. Only the admin sees For the admin. Support Wishbone shows only when the storefront
  /// and the build allow it (`SupportWishbone.shownPage`), and never to a child.
  public static func shown(isAdmin: Bool, hasParents: Bool, support: URL? = nil) -> [SettingsSection] {
    allCases.filter { section in
      switch section {
      case .forTheAdmin: isAdmin
      case .supportWishbone: support != nil && !hasParents
      default: true
      }
    }
  }
}

/// What the About section shows, the app's own address, version, and build, and the For the admin footer's link,
/// from the app's `Info.plist`.
public struct AppAbout: Equatable, Sendable {
  /// The app's repository, from the build's `WISHBONE_SOURCE_URL`. `nil` when the build has none, and then there is
  /// no Source code row.
  public let sourceCode: URL?

  /// The maker's support page, from the build's `WISHBONE_SUPPORT_URL`. `nil` when the build has none, and then
  /// there is no support row, for anyone.
  public let support: URL?

  /// The server's docs on running an instance, from the build's `WISHBONE_OPERATOR_DOCS_URL`. The For the admin
  /// footer links to it. `nil` when the build has none, and then the footer has no link.
  public let operatorDocs: URL?

  /// The app's version, such as "1.0".
  public let version: String

  /// The build number.
  public let build: String

  /// The values of an `Info.plist`.
  public init(info: [String: Any]) {
    sourceCode = Self.webAddress(info["WishboneSourceURL"])
    operatorDocs = Self.webAddress(info["WishboneOperatorDocsURL"])
    support = Self.webAddress(info["WishboneSupportURL"])
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
