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

  /// `GET /users/me`: the session's user.
  public func me() async throws(APIError) -> User {
    try await load(.me)
  }

  /// `GET /lists/{id}/items`: every item on the list, in the list's order. It follows `next_cursor` to the last
  /// page.
  public func items(ofList id: String) async throws(APIError) -> [Item] {
    var items: [Item] = []
    var cursor: String?
    repeat {
      let page = try await load(.items(ofList: id, cursor: cursor))
      items += page.data
      cursor = page.nextCursor
    } while cursor != nil
    return items
  }

  // MARK: - The one load

  /// Every request goes through here: the user agent, the token, the time limit, the log, the strict test for the
  /// API's own answers, and the rule for an unreachable instance.
  private func load<Response>(_ endpoint: Endpoint<Response>) async throws(APIError) -> Response {
    let route = endpoint.route
    guard let url = instance.url(path: endpoint.path, query: endpoint.query) else {
      Log.request(route, "has no URL")
      throw .unreachable(.notTheAPI)
    }
    var request = URLRequest(url: url)
    request.httpMethod = route.method
    request.setValue(userAgent.text, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    // The token goes only to the instance address, on a route that needs a session.
    if let token, !route.isPublic { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
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
      // No network, a timeout, a DNS failure, a TLS failure, a connection that closed: all are unreachable. The
      // rule depends on no one code of `URLError`.
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
        return decoded
      } catch {
        let undecodable = APIError.Undecodable(route: route, keyPath: JSONCoding.keyPath(of: error))
        Log.request(route, "answer can't be decoded", status: status)
        throw .undecodable(undecodable)
      }
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
