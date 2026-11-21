import Foundation

/// The client of one instance's API. It is built from the instance address, and from the session's token once the
/// device is signed in. See "The API client" in `docs/architecture.md`, and ADR 0004.
///
/// Its state is all `let`, and it is not on the main actor.
public struct APIClient: Sendable {
  public let instance: InstanceAddress

  private let token: String?
  private let userAgent: UserAgent
  private let clock: any Clock<Duration>
  private let timeout: Duration

  /// A client with no session, for the version check and the redeem of a login link.
  public init(
    instance: InstanceAddress,
    userAgent: UserAgent,
    clock: any Clock<Duration> = ContinuousClock(),
    timeout: Duration = .seconds(30)
  ) {
    self.instance = instance
    token = nil
    self.userAgent = userAgent
    self.clock = clock
    self.timeout = timeout
  }

  /// The client of a session.
  public init(
    session: Session,
    userAgent: UserAgent,
    clock: any Clock<Duration> = ContinuousClock(),
    timeout: Duration = .seconds(30)
  ) {
    instance = session.instance
    token = session.token
    self.userAgent = userAgent
    self.clock = clock
    self.timeout = timeout
  }

  // MARK: - The routes

  /// `GET /health`: the instance's version. It needs no token.
  public func health() async throws(APIError) -> Health {
    try await load(.health)
  }

  /// `POST /login-links/redeem`: uses the link, and starts a bearer session. The link works once.
  public func redeem(_ link: LoginLink) async throws(APIError) -> (session: Session, name: String) {
    let redeemed = try await load(.redeem(link))
    return (Session(instance: instance, token: redeemed.token, userID: redeemed.userID), redeemed.name)
  }

  /// `GET /versions`: the version of everything that the session's user can see, in one answer.
  ///
  /// With the `ETag` of an earlier answer, the server answers 304 when nothing has changed since, and the result
  /// is `unchanged`. The request never has a query. An API's own 404 here means an instance below the minimum
  /// server version, which has no such route.
  public func versions(ifNoneMatch etag: String?) async throws(APIError) -> VersionsAnswer {
    guard let answer = try await answer(to: .versions(ifNoneMatch: etag)) else { return .unchanged }
    return .changed(Versions(entries: answer.body.data, etag: answer.etag))
  }

  /// `GET /users/me`: the session's user. It is the answer of `GET /users/{id}` for that user, with the same
  /// `ETag`.
  public func me() async throws(APIError) -> Versioned<User> {
    try await versioned(.me)
  }

  /// `PATCH /users/me` with the time zone: sets the IANA zone on the session's own user, and gives back the user.
  public func reportTimeZone(_ identifier: String) async throws(APIError) -> User {
    try await load(.reportTimeZone(identifier))
  }

  /// `GET /lists/{id}`: one list.
  public func list(_ id: String) async throws(APIError) -> Versioned<ListResource> {
    try await versioned(.list(id))
  }

  /// `GET /lists/{id}/items`: every item on the list, in the list's order, each with its version. It follows
  /// `next_cursor` to the last page.
  public func items(ofList id: String) async throws(APIError) -> [Versioned<Item>] {
    var items: [Versioned<Item>] = []
    var cursor: String?
    repeat {
      let page = try await load(.items(ofList: id, cursor: cursor))
      items += page.data.map(\.row)
      cursor = page.nextCursor
    } while cursor != nil
    return items
  }

  /// How many rows a page of a collection has, when the request names no other size.
  public static let pageSize = 100

  /// `GET /items/{id}`: one item.
  public func item(_ id: String) async throws(APIError) -> Versioned<Item> {
    try await versioned(.item(id))
  }

  // MARK: - The one load

  /// The answer of a route with no `If-None-Match`.
  private func load<Response>(_ endpoint: Endpoint<Response>) async throws(APIError) -> Response {
    // A 304 answers only a request with `If-None-Match`, so this request has an answer.
    guard let answer = try await answer(to: endpoint) else { throw .unreachable(.notTheAPI) }
    return answer.body
  }

  /// A resource from its own address, with the `ETag` of the answer as its version.
  private func versioned<Resource>(_ endpoint: Endpoint<Resource>) async throws(APIError) -> Versioned<Resource> {
    guard let answer = try await answer(to: endpoint) else { throw .unreachable(.notTheAPI) }
    return Versioned(resource: answer.body, version: Self.version(ofETag: answer.etag))
  }

  /// The version that an `ETag` gives. `GET /versions` names a version as the strong tag, so a tag that something
  /// on the way made weak (`W/`) is the same version. An answer with no `ETag` has the empty version, which agrees
  /// with nothing that `GET /versions` names, so the resource is fetched again at the next pull.
  private static func version(ofETag etag: String?) -> String {
    guard let etag else { return "" }
    return etag.hasPrefix("W/") ? String(etag.dropFirst(2)) : etag
  }

  /// What a route answered: the decoded body, and the answer's `ETag`.
  private struct Answer<Response> {
    let body: Response
    let etag: String?
  }

  /// Every request goes through here: the user agent, the token, the time limit, the log, the strict test for the
  /// API's own answers, and the rule for an unreachable instance.
  ///
  /// Nil is a 304 for a request with `If-None-Match`: the answer that the request named still holds.
  private func answer<Response>(to endpoint: Endpoint<Response>) async throws(APIError) -> Answer<Response>? {
    let route = endpoint.route
    // A query parameter that the route doesn't name is never sent.
    let query = endpoint.query.filter { route.queryParameters.contains($0.name) }
    guard let url = instance.url(path: endpoint.path, query: query) else {
      Log.request(route, "has no URL")
      throw .unreachable(.notTheAPI)
    }
    var request = URLRequest(url: url)
    request.httpMethod = route.method
    request.setValue(userAgent.text, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    // The token goes only to the instance address, on a route that needs a session.
    if let token, !route.isPublic { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let etag = endpoint.ifNoneMatch { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
    if let body = endpoint.body {
      guard let data = try? await JSONCoding.encode(body) else { throw .undecodable(.init(route: route, keyPath: "")) }
      request.httpBody = data
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    let data: Data
    let answer: HTTPURLResponse
    do {
      let (body, response) = try await withTimeout(timeout, clock: clock) { [request] in
        try await Self.urlSession.data(for: request, delegate: NoRedirects())
      }
      guard let response = response as? HTTPURLResponse else {
        Log.request(route, "is not HTTP")
        throw APIError.unreachable(.notTheAPI)
      }
      (data, answer) = (body, response)
    } catch let error as APIError {
      throw error
    } catch {
      if Task.isCancelled {
        Log.request(route, "was cancelled")
        throw .cancelled
      }
      if let error = error as? URLError, Self.untrustedCertificate.contains(error.code) {
        Log.request(route, "has a certificate that the device doesn't trust")
        throw .unreachable(.untrustedCertificate)
      }
      // Apart from the certificate codes above: no network, a timeout, a DNS failure, another TLS failure, a
      // connection that closed. All are unreachable, and the rule depends on no one code of `URLError`.
      Log.request(route, error is TimedOut ? "timed out" : "got no answer")
      throw .unreachable(.noAnswer)
    }

    let status = answer.statusCode
    let contentType = (answer.value(forHTTPHeaderField: "Content-Type") ?? "")
      .prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces).lowercased()
    switch status {
    case 200..<300:
      guard contentType == "application/json" else {
        Log.request(route, "answer is not the API's", status: status)
        throw .unreachable(.notTheAPI)
      }
      do {
        let decoded = try await JSONCoding.decode(Response.self, from: data)
        Log.request(route, "ok", status: status)
        return Answer(body: decoded, etag: answer.value(forHTTPHeaderField: "ETag"))
      } catch {
        let undecodable = APIError.Undecodable(route: route, keyPath: JSONCoding.keyPath(of: error))
        Log.request(route, "answer can't be decoded", status: status)
        throw .undecodable(undecodable)
      }
    case 304 where endpoint.ifNoneMatch != nil:
      Log.request(route, "not modified", status: status)
      return nil
    case 500..<600:
      Log.request(route, "server error", status: status)
      throw .unreachable(.noAnswer)
    default:
      // Only the API's own answer counts: a problem with a code. A 401 from a reverse proxy, an access gateway, or
      // a captive portal is "unreachable", and so is a redirect.
      guard contentType == "application/problem+json",
        let problem = try? await JSONCoding.decode(Problem.self, from: data)
      else {
        Log.request(route, "answer is not the API's", status: status)
        throw .unreachable(.notTheAPI)
      }
      let code = ErrorCode(problem.code)
      Log.request(route, "refused", status: status)
      if status == 401, code == .unauthorized { throw .unauthorized }
      if status == 410, code == .apiVersionRemoved { throw .appTooOld }
      throw .refused(.init(status: status, code: code, detail: problem.detail))
    }
  }

  /// The codes of `URLError` for a certificate that the device doesn't trust. Only these name the certificate:
  /// any other failure is unreachable with no answer.
  private static let untrustedCertificate: Set<URLError.Code> = [
    .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate,
    .serverCertificateNotYetValid,
  ]

  /// The one `URLSession` of every client. It keeps no cookie and no cache: the token is the session, and the
  /// local database is the copy.
  private static let urlSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: configuration)
  }()

  /// A redirect is never followed, so a request, and the token on it, never goes to another address. The answer
  /// that redirects is the answer, and it is not the API's own.
  private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
      _ session: URLSession,
      task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest,
      completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }
  }
}

/// The one place where JSON is encoded and decoded. It is never on the main actor.
enum JSONCoding {
  @concurrent
  static func decode<Value: Decodable & Sendable>(_ type: Value.Type, from data: Data) async throws -> Value {
    try JSONDecoder().decode(type, from: data)
  }

  @concurrent
  static func encode(_ value: any Encodable & Sendable) async throws -> Data {
    try JSONEncoder().encode(value)
  }

  /// The key path where a decode failed, such as `data[].title`. It names keys only, never a value.
  static func keyPath(of error: any Error) -> String {
    let path: [any CodingKey]
    switch error as? DecodingError {
    case .keyNotFound(let key, let context): path = context.codingPath + [key]
    case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
      path = context.codingPath
    default: path = []
    }
    return path.reduce(into: "") { text, key in
      if key.intValue != nil {
        text += "[]"
      } else {
        text += text.isEmpty ? key.stringValue : ".\(key.stringValue)"
      }
    }
  }
}
