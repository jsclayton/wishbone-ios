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

  /// The user's IANA time zone, such as `Europe/Paris`. Nil when none is set, and when the caller can't see it:
  /// only the user, their parents, and the admin see it.
  public let timezone: String?

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case name
    case primaryList = "primary_list"
    case timezone
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

/// A list, as `GET /lists/{id}` gives it. Its name is not `List`, which is SwiftUI's.
public struct ListResource: Model, Equatable {
  public let id: String
  public let name: String

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case name
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self)
}

/// An item, as `GET /items/{id}` gives it, and as a row of `GET /lists/{id}/items`.
public struct Item: Model, Equatable {
  public let id: String
  public let listID: String
  public let title: String

  /// The item's place on its list, from 0.
  public let position: Int

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case listID = "list_id"
    case title
    case position
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self)
}

/// A resource, with its version as this caller sees it.
///
/// The version comes from the resource's own answer: the `ETag` of its `GET`, or its `version` as a row of a
/// collection. The two are one value, and `GET /versions` names the same one. See "Versions of everything a caller
/// sees" in the server's spec.
public struct Versioned<Resource: Sendable>: Sendable {
  public let resource: Resource
  public let version: String
}

extension Versioned: Equatable where Resource: Equatable {}

/// A row of a collection: the resource, and its `version` beside the resource's own fields.
struct VersionedRow<Resource: Model>: Model {
  let row: Versioned<Resource>

  enum CodingKeys: String, CodingKey, CaseIterable {
    case version
  }

  init(from decoder: any Decoder) throws {
    let version = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .version)
    row = Versioned(resource: try Resource(from: decoder), version: version)
  }

  static var fields: [String] {
    Resource.fields + WishboneAPI.fields(of: CodingKeys.self)
  }
}

/// One entry of `GET /versions`: a resource that this caller can see, and its version.
public struct ResourceVersion: Model, Equatable {
  public let kind: Kind
  public let id: String

  /// The same value as the `ETag` of the resource's own `GET`, and as its `version` in a collection.
  public let version: String

  /// The list of an item. Nil for a kind that is on no list.
  public let listID: String?

  /// What an entry is. The enum is open: a kind that the app doesn't know is `unknown`, and the app ignores its
  /// entries. The server has more kinds than these. A kind joins the list when the copy starts to hold it.
  public enum Kind: Sendable, Hashable, Decodable {
    case user
    case list
    case item
    case unknown(String)

    private static let known: [String: Kind] = ["user": .user, "list": .list, "item": .item]

    /// The kind for the server's text, such as `item`.
    public init(_ text: String) {
      self = Self.known[text] ?? .unknown(text)
    }

    public init(from decoder: any Decoder) throws {
      self.init(try decoder.singleValueContainer().decode(String.self))
    }
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case kind
    case id
    case version
    case listID = "list_id"
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self)
}

/// The answer of `GET /versions`. It is one answer, with no pages.
struct VersionsBody: Model {
  let data: [ResourceVersion]

  enum CodingKeys: String, CodingKey {
    case data
  }

  static let fields = ResourceVersion.fields.map { "\(CodingKeys.data.stringValue)[].\($0)" }
}

/// What `GET /versions` says: the version of every resource that this caller can see.
public struct Versions: Sendable, Equatable {
  /// One entry for each resource, in no order. A resource with no entry is gone for this caller: deleted, moved
  /// out of view, or hidden. The answer doesn't say which.
  public let entries: [ResourceVersion]

  /// The `ETag` of the whole answer. Sent back as `If-None-Match`, it gets a 304 while no entry has changed.
  public let etag: String?
}

/// How `GET /versions` answered a request that could carry the `ETag` of an earlier answer.
public enum VersionsAnswer: Sendable, Equatable {
  /// A 304: nothing that the earlier answer covers has changed for this caller.
  case unchanged

  /// A 200: the versions as they are now.
  case changed(Versions)
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
