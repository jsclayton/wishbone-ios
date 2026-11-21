import Foundation

/// Every route of the API that the client calls. The contract test holds each one against the copy of the server's
/// OpenAPI document, so a route that is not here is a route that the app doesn't call. See ADR 0004.
public enum Route: String, Sendable, CaseIterable {
  case health
  case redeemLoginLink
  case versions
  case me
  case updateMe
  case list
  case listItems
  case item

  public var method: String {
    switch self {
    case .health, .versions, .me, .list, .listItems, .item: "GET"
    case .redeemLoginLink: "POST"
    case .updateMe: "PATCH"
    }
  }

  /// The path template under `/api/v2`, as the server's route table writes it.
  public var template: String {
    switch self {
    case .health: "/health"
    case .redeemLoginLink: "/login-links/redeem"
    case .versions: "/versions"
    case .me, .updateMe: "/users/me"
    case .list: "/lists/{id}"
    case .listItems: "/lists/{id}/items"
    case .item: "/items/{id}"
    }
  }

  /// Whether the route is for anyone, signed in or not. A request on such a route never carries the token. So a
  /// redeem never has an `Authorization` header, and the server never revokes a session that the app holds.
  public var isPublic: Bool {
    switch self {
    case .health, .redeemLoginLink: true
    case .versions, .me, .updateMe, .list, .listItems, .item: false
    }
  }

  /// The query parameters that the client sends on the route. A request never carries another one.
  ///
  /// `GET /versions` has none, and never gets one: the server refuses that route with any query parameter.
  public var queryParameters: [String] {
    switch self {
    case .listItems: ["cursor"]
    case .health, .redeemLoginLink, .versions, .me, .updateMe, .list, .item: []
    }
  }

  /// The fields of the JSON body that the client sends.
  public var sentFields: [String] {
    switch self {
    case .redeemLoginLink: fields(of: RedeemBody.CodingKeys.self)
    case .updateMe: fields(of: UserChanges.CodingKeys.self)
    case .health, .versions, .me, .list, .listItems, .item: []
    }
  }

  /// The fields that the client reads from the route's answer, as key paths.
  public var decodedFields: [String] {
    switch self {
    case .health: Health.fields
    case .redeemLoginLink: RedeemedLoginLink.fields
    case .versions: VersionsBody.fields
    case .me, .updateMe: User.fields
    case .list: ListResource.fields
    case .listItems: Page<VersionedRow<Item>>.fields
    case .item: Item.fields
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
  static var me: Endpoint {
    Endpoint(route: .me)
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

extension Endpoint where Response == ListResource {
  static func list(_ id: String) -> Endpoint {
    Endpoint(route: .list, parameters: ["id": id])
  }
}

extension Endpoint where Response == Page<VersionedRow<Item>> {
  static func items(ofList id: String, cursor: String?) -> Endpoint {
    Endpoint(
      route: .listItems, parameters: ["id": id], query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
  }
}

extension Endpoint where Response == Item {
  static func item(_ id: String) -> Endpoint {
    Endpoint(route: .item, parameters: ["id": id])
  }
}
