import Foundation

/// Every route of the API that the client calls. The contract test holds each one against the copy of the server's
/// OpenAPI document, so a route that is not here is a route that the app doesn't call. See ADR 0004.
public enum Route: String, Sendable, CaseIterable {
  case health
  case redeemLoginLink
  case versions
  case updateMe
  case users
  case user
  case groups
  case group
  case groupUsers
  case groupGroups
  case occasions
  case occasion
  case occasionGroups
  case lists
  case list
  case listRecipients
  case listItems
  case item
  case invitations
  case invitation
  case revokeCurrentSession

  public var method: String {
    switch self {
    case .health, .versions, .users, .user, .groups, .group, .groupUsers, .groupGroups, .occasions, .occasion,
      .occasionGroups, .lists, .list, .listRecipients, .listItems, .item, .invitations, .invitation:
      "GET"
    case .redeemLoginLink: "POST"
    case .updateMe: "PATCH"
    case .revokeCurrentSession: "DELETE"
    }
  }

  /// The path template under `/api/v2`, as the server's route table writes it.
  public var template: String {
    switch self {
    case .health: "/health"
    case .redeemLoginLink: "/login-links/redeem"
    case .versions: "/versions"
    case .updateMe: "/users/me"
    case .users: "/users"
    case .user: "/users/{id}"
    case .groups: "/groups"
    case .group: "/groups/{id}"
    case .groupUsers: "/groups/{id}/users"
    case .groupGroups: "/groups/{id}/groups"
    case .occasions: "/occasions"
    case .occasion: "/occasions/{id}"
    case .occasionGroups: "/occasions/{id}/groups"
    case .lists: "/lists"
    case .list: "/lists/{id}"
    case .listRecipients: "/lists/{id}/recipients"
    case .listItems: "/lists/{id}/items"
    case .item: "/items/{id}"
    case .invitations: "/invitations"
    case .invitation: "/invitations/{id}"
    case .revokeCurrentSession: "/users/me/sessions/current"
    }
  }

  /// Whether the route is for anyone, signed in or not. A request on such a route never carries the token. So a
  /// redeem never has an `Authorization` header, and the server never revokes a session that the app holds.
  public var isPublic: Bool {
    switch self {
    case .health, .redeemLoginLink: true
    case .versions, .updateMe, .users, .user, .groups, .group, .groupUsers, .groupGroups, .occasions, .occasion,
      .occasionGroups, .lists, .list, .listRecipients, .listItems, .item, .invitations, .invitation,
      .revokeCurrentSession:
      false
    }
  }

  /// The query parameters that the client sends on the route. A request never carries another one: the client
  /// drops a parameter that is not here, so every filter that the client uses must be.
  ///
  /// `GET /versions` has none, and never gets one: the server refuses that route with any query parameter.
  public var queryParameters: [String] {
    switch self {
    // The two filters give the memberships: the users in a group with nesting, and the users of an occasion.
    case .users: Self.paging + ["group_id", "occasion_id"]
    // The filter gives the lists that the session's user is a recipient of.
    case .lists: Self.paging + ["recipient_id"]
    case .groups, .groupUsers, .groupGroups, .occasions, .occasionGroups, .listRecipients, .listItems, .invitations:
      Self.paging
    case .health, .redeemLoginLink, .versions, .updateMe, .user, .group, .occasion, .list, .item, .invitation,
      .revokeCurrentSession:
      []
    }
  }

  /// What every collection takes: the size of a page, and the place of the next one.
  private static let paging = ["limit", "cursor"]

  /// The fields of the JSON body that the client sends.
  public var sentFields: [String] {
    switch self {
    case .redeemLoginLink: fields(of: RedeemBody.CodingKeys.self)
    case .updateMe: fields(of: UserChanges.CodingKeys.self)
    case .health, .versions, .users, .user, .groups, .group, .groupUsers, .groupGroups, .occasions, .occasion,
      .occasionGroups, .lists, .list, .listRecipients, .listItems, .item, .invitations, .invitation,
      .revokeCurrentSession:
      []
    }
  }

  /// The fields that the client reads from the route's answer, as key paths. A route whose answer has no body
  /// (a 204) has none.
  public var decodedFields: [String] {
    switch self {
    case .health: Health.fields
    case .redeemLoginLink: RedeemedLoginLink.fields
    case .versions: VersionsBody.fields
    case .updateMe, .user: User.fields
    case .users: Page<VersionedRow<User>>.fields
    case .groups: Page<VersionedRow<Group>>.fields
    case .group: Group.fields
    case .occasions: Page<VersionedRow<Occasion>>.fields
    case .occasion: Occasion.fields
    // A membership is read for its IDs only.
    case .groupUsers, .groupGroups, .occasionGroups: Page<Member>.fields
    case .lists: Page<VersionedRow<ListResource>>.fields
    case .list: ListResource.fields
    case .listRecipients: Page<VersionedRow<Recipient>>.fields
    case .listItems: Page<VersionedRow<Item>>.fields
    case .item: Item.fields
    case .invitations: Page<VersionedRow<Invitation>>.fields
    case .invitation: Invitation.fields
    case .revokeCurrentSession: NoContent.fields
    }
  }
}

/// One request: a route, with what fills its path template, its query, its body, and its `If-None-Match`.
struct Endpoint<Response: Model>: Sendable {
  let route: Route
  var parameters: [String: String] = [:]
  var query: [URLQueryItem] = []
  var body: (any Encodable & Sendable)?

  /// The `ETag` of an earlier answer of the route. The server then answers 304, with no body, when its answer
  /// would be that one again. Only `GET /versions` takes it.
  var ifNoneMatch: String?

  /// The path under `/api/v2`, with each parameter in its place.
  var path: String {
    parameters.reduce(route.template) { path, parameter in
      // An ID is an opaque string, so it is encoded as one part of a path.
      let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
      let value = parameter.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? parameter.value
      return path.replacingOccurrences(of: "{\(parameter.key)}", with: value)
    }
  }
}

/// The body of a redeem. A native app asks for a bearer session, which puts the token in the answer.
struct RedeemBody: Encodable, Sendable {
  let token: String
  let session = "bearer"

  enum CodingKeys: String, CodingKey, CaseIterable {
    case token
    case session
  }
}

extension Endpoint where Response == Health {
  static var health: Endpoint {
    Endpoint(route: .health)
  }
}

extension Endpoint where Response == RedeemedLoginLink {
  static func redeem(_ link: LoginLink) -> Endpoint {
    Endpoint(route: .redeemLoginLink, body: RedeemBody(token: link.token))
  }
}

/// The body of `PATCH /users/me`: a merge patch, so a field that is absent doesn't change. The app sets only the
/// time zone.
struct UserChanges: Encodable, Sendable {
  let timezone: String

  enum CodingKeys: String, CodingKey, CaseIterable {
    case timezone
  }
}

extension Endpoint where Response == User {
  static func user(_ id: String) -> Endpoint {
    Endpoint(route: .user, parameters: ["id": id])
  }

  /// Only the session's own user, `me`, is ever patched with a zone. The app never reports a child's.
  static func reportTimeZone(_ identifier: String) -> Endpoint {
    Endpoint(route: .updateMe, body: UserChanges(timezone: identifier))
  }
}

extension Endpoint where Response == VersionsBody {
  static func versions(ifNoneMatch etag: String?) -> Endpoint {
    Endpoint(route: .versions, ifNoneMatch: etag)
  }
}

extension Endpoint where Response == Group {
  static func group(_ id: String) -> Endpoint {
    Endpoint(route: .group, parameters: ["id": id])
  }
}

extension Endpoint where Response == Occasion {
  static func occasion(_ id: String) -> Endpoint {
    Endpoint(route: .occasion, parameters: ["id": id])
  }
}

extension Endpoint where Response == ListResource {
  static func list(_ id: String) -> Endpoint {
    Endpoint(route: .list, parameters: ["id": id])
  }
}

extension Endpoint where Response == Item {
  static func item(_ id: String) -> Endpoint {
    Endpoint(route: .item, parameters: ["id": id])
  }
}

extension Endpoint where Response == Invitation {
  static func invitation(_ id: String) -> Endpoint {
    Endpoint(route: .invitation, parameters: ["id": id])
  }
}

extension Endpoint where Response == NoContent {
  /// Signs out: the server revokes the session that the token is of.
  static var revokeCurrentSession: Endpoint {
    Endpoint(route: .revokeCurrentSession)
  }
}

extension Endpoint {
  /// One page of a collection: the largest page that the server gives, from the cursor of the page before it.
  /// `filters` are the route's own query parameters, such as `group_id`.
  static func page<Row>(
    of route: Route,
    id: String? = nil,
    filters: [String: String] = [:],
    cursor: String?
  ) -> Endpoint where Response == Page<Row> {
    var query = filters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    query.append(URLQueryItem(name: "limit", value: String(APIClient.pageSize)))
    if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
    return Endpoint(route: route, parameters: id.map { ["id": $0] } ?? [:], query: query)
  }
}
