import GRDB

// The rows that screens read. Each is a row of the local copy, which the API feeds and the session model
// publishes. A row is not the API's model of the same thing: it holds what the copy keeps.

/// A user in the local copy.
public struct UserRow: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "user"

  public let id: String
  public let name: String

  /// The user's primary list. Nil when the session's user can't see it.
  public let primaryListID: String?
}

/// A list in the local copy.
public struct ListRow: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "list"

  public let id: String
  public let name: String
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
