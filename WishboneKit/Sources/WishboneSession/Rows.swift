import GRDB

// The rows that screens read. Each is a row of the local copy, which the API feeds and the session model
// publishes. A row is not the API's model of the same thing: it holds what the copy keeps.
//
// Each row keeps its version: the one that its own answer carried when the row was saved. A pull compares it with
// the version that `GET /versions` names. See "No If-Match" in `docs/spec.md`.

/// A user in the local copy.
public struct UserRow: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "user"

  public let id: String
  public let name: String

  /// The user's primary list. Nil when the session's user can't see it.
  public let primaryListID: String?

  /// The user's IANA time zone, such as `Europe/Paris`. Nil when none is set, and when the session's user can't
  /// see it.
  public let timezone: String?

  /// The version of the user as the session's user sees them.
  public let version: String
}

/// A list in the local copy.
public struct ListRow: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "list"

  public let id: String
  public let name: String

  /// The version of the list as the session's user sees it.
  public let version: String
}

/// An item in the local copy.
public struct ItemRow: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "item"

  public let id: String
  public let listID: String
  public let title: String

  /// The item's place on its list, from 0.
  public let position: Int

  /// The version of the item as the session's user sees it.
  public let version: String
}
