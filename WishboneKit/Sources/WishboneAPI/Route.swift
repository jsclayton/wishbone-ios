import Foundation

/// Every route of the API that the client calls. The contract test holds each one against the copy of the server's
/// OpenAPI document, so a route that is not here is a route that the app doesn't call. See ADR 0004.
public enum Route: String, Sendable, CaseIterable {
  case health
  case redeemLoginLink
  case me
  case listItems

  public var method: String {
    switch self {
    case .health, .me, .listItems: "GET"
    case .redeemLoginLink: "POST"
    }
  }

  /// The path template under `/api/v2`, as the server's route table writes it.
  public var template: String {
    switch self {
    case .health: "/health"
    case .redeemLoginLink: "/login-links/redeem"
    case .me: "/users/me"
    case .listItems: "/lists/{id}/items"
    }
  }

  /// Whether the route is for anyone, signed in or not. A request on such a route never carries the token. So a
  /// redeem never has an `Authorization` header, and the server never revokes a session that the app holds.
  public var isPublic: Bool {
    switch self {
    case .health, .redeemLoginLink: true
    case .me, .listItems: false
    }
  }

  /// The fields of the JSON body that the client sends.
  public var sentFields: [String] {
    switch self {
    case .redeemLoginLink: fields(of: RedeemBody.CodingKeys.self)
    case .health, .me, .listItems: []
    }
  }

  /// The fields that the client reads from the route's answer, as key paths.
  public var decodedFields: [String] {
    switch self {
    case .health: Health.fields
    case .redeemLoginLink: RedeemedLoginLink.fields
    case .me: User.fields
    case .listItems: Page<Item>.fields
    }
  }
}

/// One request: a route, with what fills its path template, its query, and its body.
struct Endpoint<Response: Model>: Sendable {
  let route: Route
  var parameters: [String: String] = [:]
  var query: [URLQueryItem] = []
  var body: (any Encodable & Sendable)?

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

extension Endpoint where Response == User {
  static var me: Endpoint {
    Endpoint(route: .me)
  }
}

extension Endpoint where Response == Page<Item> {
  static func items(ofList id: String, cursor: String?) -> Endpoint {
    Endpoint(
      route: .listItems, parameters: ["id": id], query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
  }
}
