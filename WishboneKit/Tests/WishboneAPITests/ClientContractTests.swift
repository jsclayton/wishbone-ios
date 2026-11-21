import Foundation
import TestSupport
import Testing
import WishboneAPI

/// The client against the copy of the pinned server's OpenAPI document, with no server. See ADR 0004.
@Suite("The client's routes are in the copy of the OpenAPI document", .timeLimit(.minutes(1)))
struct ClientContractTests {
  let document: JSON

  init() throws {
    document = try JSON(parsing: Data(contentsOf: ServerBuild.current.openAPIFile))
  }

  @Test("The copy has the route", arguments: Route.allCases)
  func routeIsInTheCopy(route: Route) throws {
    _ = try operation(of: route)
  }

  @Test("A route carries the token exactly when the copy says that it needs a session", arguments: Route.allCases)
  func routeNeedsASession(route: Route) throws {
    let needsSession = try operation(of: route)["security"].array?.contains { $0["bearerAuth"] != .null } ?? false
    #expect(route.isPublic == !needsSession)
  }

  @Test("Every field that the client reads is in the route's answer", arguments: Route.allCases)
  func decodedFieldsAreInTheAnswer(route: Route) throws {
    let responses = try operation(of: route)["responses"]
    let answer = responses["200"]["content"]["application/json"]["schema"]
    #expect(answer != .null, "\(route.method) \(route.template) has no 200 answer in the copy")
    #expect(!route.decodedFields.isEmpty)
    for field in route.decodedFields {
      #expect(schema(at: field, in: answer) != nil, "\(route.method) \(route.template) has no \(field) in its answer")
    }
  }

  @Test("Every field that the client sends is in the route's body", arguments: Route.allCases)
  func sentFieldsAreInTheBody(route: Route) throws {
    let body = try operation(of: route)["requestBody"]["content"]["application/json"]["schema"]
    for field in route.sentFields {
      #expect(schema(at: field, in: body) != nil, "\(route.method) \(route.template) takes no \(field) in its body")
    }
  }

  @Test("Every query parameter that the client sends is one that the route takes", arguments: Route.allCases)
  func queryParametersAreInTheCopy(route: Route) throws {
    let taken = try parameters(of: route, in: "query")
    for name in route.queryParameters {
      #expect(taken.contains(name), "\(route.method) \(route.template) takes no \(name) in its query")
    }
  }

  @Test("GET /versions is in the copy with its 304 and its If-None-Match, and the client's request has no query")
  func versions() throws {
    let operation = try operation(of: .versions)
    #expect(operation["responses"]["304"] != .null)
    #expect(try parameters(of: .versions, in: "header").contains("If-None-Match"))
    // The server refuses this route with any query parameter, whatever its name. So the copy gives it none, and
    // the client must send none.
    #expect(try parameters(of: .versions, in: "query").isEmpty)
    #expect(Route.versions.queryParameters.isEmpty)
    // The answer is one response, with no pages to follow.
    let answer = operation["responses"]["200"]["content"]["application/json"]["schema"]
    #expect(schema(at: "data[].kind", in: answer) != nil)
    #expect(schema(at: "next_cursor", in: answer) == nil)
  }

  @Test("The check finds what is missing: a route, and a field")
  func checkFindsWhatIsMissing() throws {
    #expect(throws: NotInTheCopy.self) { try operation(method: "GET", template: "/wishes/{id}") }
    #expect(throws: NotInTheCopy.self) { try operation(method: "DELETE", template: "/health") }
    let user = try operation(method: "GET", template: "/users/me")["responses"]["200"]["content"]["application/json"][
      "schema"]
    #expect(schema(at: "primary_list.id", in: user) != nil)
    #expect(schema(at: "primary_list.title", in: user) == nil)
    #expect(schema(at: "nickname", in: user) == nil)
    let items = try operation(method: "GET", template: "/lists/{id}/items")["responses"]["200"]["content"][
      "application/json"]["schema"]
    #expect(schema(at: "data[].title", in: items) != nil)
    #expect(schema(at: "data[].name", in: items) == nil)
  }

  // MARK: - Reading the copy

  struct NotInTheCopy: Error, CustomStringConvertible {
    let description: String
  }

  private func operation(of route: Route) throws -> JSON {
    try operation(method: route.method, template: route.template)
  }

  /// The names of the parameters that the copy gives the route in one place: `query`, `header`, or `path`.
  private func parameters(of route: Route, in place: String) throws -> [String] {
    let parameters = try operation(of: route)["parameters"].array ?? []
    return parameters.filter { $0["in"].string == place }.compactMap { $0["name"].string }
  }

  /// The operation of a method and a path template. In a template, `me` stands for a user's ID and `current` for
  /// a session's ID, as the server's route table says, so each matches a parameter of the copy's path.
  private func operation(method: String, template: String) throws -> JSON {
    guard case .object(let paths) = document["paths"] else { throw NotInTheCopy(description: "The copy has no paths.") }
    let wanted = (TestServer.apiPrefix + template).split(separator: "/")
    let path = paths.keys.sorted().first { path in
      let parts = path.split(separator: "/")
      return parts.count == wanted.count
        && zip(parts, wanted).allSatisfy { part, wanted in
          part == wanted || (part.hasPrefix("{") && (wanted.hasPrefix("{") || wanted == "me" || wanted == "current"))
        }
    }
    guard let path, case let operation = document["paths"][path][method.lowercased()], operation != .null else {
      throw NotInTheCopy(description: "The copy has no \(method) \(template).")
    }
    return operation
  }

  /// The schema at a key path under a schema, such as `data[].title`. Nil when the schema has no such field.
  private func schema(at keyPath: String, in schema: JSON) -> JSON? {
    var current = resolved(schema)
    for part in keyPath.split(separator: ".") {
      let isArray = part.hasSuffix("[]")
      current = resolved(current["properties"][String(isArray ? part.dropLast(2) : part)])
      if isArray { current = resolved(current["items"]) }
      if current == .null { return nil }
    }
    return current
  }

  /// The schema itself, or the one that its `$ref` names.
  private func resolved(_ schema: JSON) -> JSON {
    guard let reference = schema["$ref"].string, let name = reference.split(separator: "/").last else { return schema }
    return document["components"]["schemas"][String(name)]
  }
}
