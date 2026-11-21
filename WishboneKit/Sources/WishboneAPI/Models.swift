/// A model that the client decodes from an answer of the API.
///
/// A model ignores the keys that it doesn't name, so a new field on the server breaks nothing. It names the fields
/// that it reads, so the contract test can hold them against the copy of the server's OpenAPI document. See
/// ADR 0004.
public protocol Model: Decodable, Sendable {
  /// The fields that the model reads, as key paths: `name`, `primary_list.id`, `data[].title`.
  static var fields: [String] { get }
}

/// The fields of a model with the given coding keys. `nested` gives the fields of each key that holds a model.
func fields<Key: CodingKey & CaseIterable>(of keys: Key.Type, nested: [String: [String]] = [:]) -> [String] {
  keys.allCases.flatMap { key in
    nested[key.stringValue]?.map { "\(key.stringValue).\($0)" } ?? [key.stringValue]
  }
}

/// The answer of `GET /health`.
public struct Health: Model, Equatable {
  /// The instance's Wishbone version, such as `2.2.0+7773ada`. A development build reports `dev`.
  public let version: String

  enum CodingKeys: String, CodingKey, CaseIterable {
    case version
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self)
}

/// The answer of `POST /login-links/redeem` for a bearer session.
public struct RedeemedLoginLink: Model {
  /// The new session's token. This answer is the only place where it appears.
  let token: String
  public let userID: String

  /// The first name of the user that the link signs in.
  public let name: String

  enum CodingKeys: String, CodingKey, CaseIterable {
    case token
    case userID = "user_id"
    case name
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self)
}

/// A user, as `GET /users/{id}` gives it.
public struct User: Model, Equatable {
  public let id: String
  public let name: String

  /// The user's primary list. The key is absent for a caller who can't see the list.
  public let primaryList: ListSummary?

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case name
    case primaryList = "primary_list"
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self, nested: ["primary_list": ListSummary.fields])
}

/// A list by its name, inside another resource.
public struct ListSummary: Model, Equatable {
  public let id: String
  public let name: String

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case name
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self)
}

/// An item, as a row of `GET /lists/{id}/items`.
public struct Item: Model, Equatable {
  public let id: String
  public let listID: String
  public let title: String

  /// The item's place on its list, from 0.
  public let position: Int

  /// The version of the item as this caller sees it.
  public let version: String

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case listID = "list_id"
    case title
    case position
    case version
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self)
}

/// One page of a collection. The client always follows `next_cursor` to the last page.
struct Page<Row: Model>: Model {
  let data: [Row]
  let nextCursor: String?

  enum CodingKeys: String, CodingKey, CaseIterable {
    case data
    case nextCursor = "next_cursor"
  }

  static var fields: [String] {
    WishboneAPI.fields(of: CodingKeys.self, nested: ["data": Row.fields]).map {
      $0.hasPrefix("data.") ? "data[]." + $0.dropFirst("data.".count) : $0
    }
  }
}

/// An error of the API, as `application/problem+json`.
struct Problem: Decodable, Sendable {
  let code: String
  let detail: String
}
