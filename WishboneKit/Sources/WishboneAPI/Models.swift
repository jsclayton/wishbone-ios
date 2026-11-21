import Foundation

/// A model that the client decodes from an answer of the API.
///
/// A model ignores the keys that it doesn't name, so a new field on the server breaks nothing. It names the fields
/// that it reads, so the contract test can hold them against the copy of the server's OpenAPI document. See
/// ADR 0004.
public protocol Model: Decodable, Sendable {
  /// The fields that the model reads, as key paths: `name`, `primary_list.id`, `data[].title`.
  static var fields: [String] { get }
}

/// The fields of a model with the given coding keys. `nested` gives the fields of each key that holds a model, and
/// `lists` gives the fields of each key that holds a list of models: `parents[].name`.
func fields<Key: CodingKey & CaseIterable>(
  of keys: Key.Type,
  nested: [String: [String]] = [:],
  lists: [String: [String]] = [:]
) -> [String] {
  keys.allCases.flatMap { key in
    let name = key.stringValue
    if let fields = nested[name] { return fields.map { "\(name).\($0)" } }
    if let fields = lists[name] { return fields.map { "\(name)[].\($0)" } }
    return [name]
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

/// A user, as `GET /users/{id}` gives it, and as a row of `GET /users`: every field that this caller gets. See
/// "User fields" in the server's route table.
public struct User: Model, Equatable {
  public let id: String
  public let name: String
  public let lastName: String?
  public let avatar: ImageSummary?

  /// Every user has one. Its year can be nil.
  public let birthday: PartialDate

  /// One markdown field that givers can see, such as sizes and allergies.
  public let goodToKnow: String?
  public let isAdmin: Bool

  /// The user's parents and children, as summaries. The caller can see each of them only as that summary, unless
  /// the caller also sees them as a user.
  public let parents: [UserSummary]
  public let children: [UserSummary]

  /// The user's primary list. The key is absent for a caller who can't see the list: the admin's access to every
  /// user shows no list. Every user has a primary list, so the field is never `null`.
  public let primaryList: ListSummary?

  /// The user's IANA time zone, such as `Europe/Paris`. Only the user, their parents, and the admin see it.
  public let timezone: Hideable<String>

  /// When the user confirmed their profile. Only the user, their parents, and the admin see it.
  public let profileConfirmedAt: Hideable<Date>

  /// When the admin deactivated the user. Only the user, their parents, and the admin see it. Anyone else who
  /// sees the user sees an active one.
  public let deactivatedAt: Hideable<Date>
  public let createdAt: Date

  public let canEdit: Bool
  public let canEditParents: Bool
  public let canMakeLoginLink: Bool
  public let canManageSessions: Bool
  public let canDeactivate: Bool
  public let canReactivate: Bool
  public let canConfirmProfile: Bool
  public let canAddOccasion: Bool

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case name
    case lastName = "last_name"
    case avatar
    case birthday
    case goodToKnow = "good_to_know"
    case isAdmin = "is_admin"
    case parents
    case children
    case primaryList = "primary_list"
    case timezone
    case profileConfirmedAt = "profile_confirmed_at"
    case deactivatedAt = "deactivated_at"
    case createdAt = "created_at"
    case canEdit = "can_edit"
    case canEditParents = "can_edit_parents"
    case canMakeLoginLink = "can_make_login_link"
    case canManageSessions = "can_manage_sessions"
    case canDeactivate = "can_deactivate"
    case canReactivate = "can_reactivate"
    case canConfirmProfile = "can_confirm_profile"
    case canAddOccasion = "can_add_occasion"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    lastName = try container.decodeIfPresent(String.self, forKey: .lastName)
    avatar = try container.decodeIfPresent(ImageSummary.self, forKey: .avatar)
    birthday = try container.decode(PartialDate.self, forKey: .birthday)
    goodToKnow = try container.decodeIfPresent(String.self, forKey: .goodToKnow)
    isAdmin = try container.decode(Bool.self, forKey: .isAdmin)
    parents = try container.decode([UserSummary].self, forKey: .parents)
    children = try container.decode([UserSummary].self, forKey: .children)
    primaryList = try container.decodeIfPresent(ListSummary.self, forKey: .primaryList)
    timezone = try container.hideable(String.self, forKey: .timezone)
    profileConfirmedAt = try container.hideableTimestamp(forKey: .profileConfirmedAt)
    deactivatedAt = try container.hideableTimestamp(forKey: .deactivatedAt)
    createdAt = try container.timestamp(forKey: .createdAt)
    canEdit = try container.decode(Bool.self, forKey: .canEdit)
    canEditParents = try container.decode(Bool.self, forKey: .canEditParents)
    canMakeLoginLink = try container.decode(Bool.self, forKey: .canMakeLoginLink)
    canManageSessions = try container.decode(Bool.self, forKey: .canManageSessions)
    canDeactivate = try container.decode(Bool.self, forKey: .canDeactivate)
    canReactivate = try container.decode(Bool.self, forKey: .canReactivate)
    canConfirmProfile = try container.decode(Bool.self, forKey: .canConfirmProfile)
    canAddOccasion = try container.decode(Bool.self, forKey: .canAddOccasion)
  }

  public static let fields = WishboneAPI.fields(
    of: CodingKeys.self,
    nested: ["avatar": ImageSummary.fields, "birthday": PartialDate.fields, "primary_list": ListSummary.fields],
    lists: ["parents": UserSummary.fields, "children": UserSummary.fields])
}

/// A user by their name and avatar, inside another resource. A summary has no last name, and no address.
public struct UserSummary: Model, Equatable {
  public let id: String
  public let name: String
  public let avatar: ImageSummary?

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case name
    case avatar
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self, nested: ["avatar": ImageSummary.fields])
}

/// A group, as `GET /groups/{id}` gives it, and as a row of `GET /groups`.
public struct Group: Model, Equatable {
  public let id: String
  public let name: String
  public let createdAt: Date

  /// The group that the caller is directly in, and that this group contains by nesting. Nil when the caller is
  /// directly in this group, or is not in it.
  public let through: GroupSummary?

  public let canEdit: Bool
  public let canDelete: Bool
  public let canAddUser: Bool
  public let canAddGroup: Bool

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case name
    case createdAt = "created_at"
    case through
    case canEdit = "can_edit"
    case canDelete = "can_delete"
    case canAddUser = "can_add_user"
    case canAddGroup = "can_add_group"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    createdAt = try container.timestamp(forKey: .createdAt)
    through = try container.decodeIfPresent(GroupSummary.self, forKey: .through)
    canEdit = try container.decode(Bool.self, forKey: .canEdit)
    canDelete = try container.decode(Bool.self, forKey: .canDelete)
    canAddUser = try container.decode(Bool.self, forKey: .canAddUser)
    canAddGroup = try container.decode(Bool.self, forKey: .canAddGroup)
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self, nested: ["through": GroupSummary.fields])
}

/// A group by its name, inside another resource.
public struct GroupSummary: Model, Equatable {
  public let id: String
  public let name: String

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case name
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self)
}

/// An occasion, as `GET /occasions/{id}` gives it, and as a row of `GET /occasions`.
public struct Occasion: Model, Equatable {
  public let id: String
  public let kind: OccasionKind

  /// A birthday's name is always "Birthday".
  public let name: String
  public let rule: OccasionRule

  /// The user that the occasion is for. Nil for a shared occasion.
  public let user: UserSummary?

  /// For a shared occasion: whether it applies to every user. Nil for the other kinds.
  public let isEveryone: Bool?

  /// The first date of the occasion that is today or later, as `YYYY-MM-DD`. Nil when none is left.
  public let nextDate: String?

  public let canEdit: Bool
  public let canDelete: Bool
  public let canAttachGroup: Bool

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case kind
    case name
    case rule
    case user
    case isEveryone = "is_everyone"
    case nextDate = "next_date"
    case canEdit = "can_edit"
    case canDelete = "can_delete"
    case canAttachGroup = "can_attach_group"
  }

  public static let fields = WishboneAPI.fields(
    of: CodingKeys.self, nested: ["rule": OccasionRule.fields, "user": UserSummary.fields])
}

/// A row of a collection that the client reads only for the IDs of its members, in the collection's order.
struct Member: Model {
  let id: String

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
  }

  static let fields = WishboneAPI.fields(of: CodingKeys.self)
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
    /// A user whom the caller sees in full.
    case user

    /// A user whom the caller gets only as a summary inside another resource. Its version is a hash of the
    /// summary: a summary has no address.
    case userSummary
    case list
    case item
    case occasion
    case group

    /// The memberships. Each entry is one collection of IDs, with the ID of its group or its occasion. Its
    /// version is a hash of the IDs that the collection gives this caller, in the collection's order.
    ///
    /// `GET /groups/{id}/users`: the users directly in a group.
    case groupUsers

    /// `GET /groups/{id}/groups`: the groups directly in a group. Only the admin has these entries.
    case groupGroups

    /// `GET /occasions/{id}/groups`: the groups that a shared occasion is attached to. Only the admin has these
    /// entries.
    case occasionGroups

    /// `GET /users?group_id=`: the users in a group, directly or through nesting.
    case usersInGroup

    /// `GET /users?occasion_id=`: the users that an occasion applies to.
    case usersOfOccasion
    case unknown(String)

    private static let known: [String: Kind] = [
      "user": .user, "user_summary": .userSummary, "list": .list, "item": .item, "occasion": .occasion,
      "group": .group, "group_users": .groupUsers, "group_groups": .groupGroups,
      "occasion_groups": .occasionGroups, "users_in_group": .usersInGroup, "users_of_occasion": .usersOfOccasion,
    ]

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
    WishboneAPI.fields(of: CodingKeys.self, lists: ["data": Row.fields])
  }
}

/// A whole collection, as the client read it: every row of every page.
public struct FetchedCollection<Row: Sendable>: Sendable {
  public let rows: [Row]

  /// Whether the collection came in one page, which is one answer of the instance. Only then is a thing that is
  /// not in `rows` not in the collection. Between two pages, a thing can change its place in the collection's
  /// order, and be on neither page.
  public let isOnePage: Bool
}

/// An error of the API, as `application/problem+json`.
struct Problem: Decodable, Sendable {
  let code: String
  let detail: String
}
