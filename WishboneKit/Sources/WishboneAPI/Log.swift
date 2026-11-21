import os

/// The app's log. This is the one file that makes a `Logger`.
///
/// Family content (names, titles, notes, addresses) in a log line is always `.private`. So a line's words are in
/// the code, as a `StaticString`, and anything else goes through a parameter that this file marks.
public enum Log {
  public enum Category: String, Sendable {
    case api
    case session
  }

  private static let loggers: [Category: Logger] = [
    .api: Logger(subsystem: subsystem, category: Category.api.rawValue),
    .session: Logger(subsystem: subsystem, category: Category.session.rawValue),
  ]

  private static let subsystem = "wishbone"

  /// A line whose words are all in the code.
  public static func note(_ category: Category, _ message: StaticString) {
    loggers[category]?.info("\(message.description, privacy: .public)")
  }

  /// A line about a fault of the app. `detail` is private: it can hold family content.
  public static func fault(_ category: Category, _ message: StaticString, detail: String = "") {
    loggers[category]?.fault("\(message.description, privacy: .public) \(detail, privacy: .private)")
  }

  /// A request and how it ended. The route gives the method and the path template, which hold nothing of the
  /// family's: never the instance address, the query, a header, or a body.
  static func request(_ route: Route, _ outcome: StaticString, status: Int? = nil) {
    let status = status.map(String.init) ?? "-"
    loggers[.api]?.info(
      """
      \(route.method, privacy: .public) \(route.template, privacy: .public): \
      \(outcome.description, privacy: .public) \(status, privacy: .public)
      """
    )
  }
}
