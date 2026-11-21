import Foundation

/// The plain HTTP that the harness and the fixture builder speak to a test server. It keeps no cookies and no
/// cache, and follows no redirect.
public enum TestHTTP {
  /// One answer from a server.
  public struct Answer: Sendable {
    public let method: String
    public let url: URL
    public let status: Int

    /// The headers, with their names in lower case.
    public let headers: [String: String]
    public let body: Data

    /// The body as JSON.
    public var json: JSON {
      get throws {
        try JSON(parsing: body)
      }
    }

    /// The answer, when its status is one of `statuses`. Otherwise the error says what the server answered.
    @discardableResult
    public func expecting(_ statuses: Int...) throws -> Answer {
      guard statuses.contains(status) else { throw UnexpectedAnswer(answer: self, wanted: statuses) }
      return self
    }
  }

  public struct UnexpectedAnswer: Error, CustomStringConvertible {
    public let answer: Answer
    public let wanted: [Int]

    public var description: String {
      let wanted = wanted.map(String.init).joined(separator: " or ")
      let body = String(decoding: answer.body, as: UTF8.self)
      return "\(answer.method) \(answer.url.absoluteString) answered \(answer.status), not \(wanted): \(body)"
    }
  }

  /// Sends one request. A JSON body goes with its content type.
  public static func send(
    _ method: String,
    _ url: URL,
    headers: [String: String] = [:],
    json: JSON? = nil
  ) async throws -> Answer {
    var request = URLRequest(url: url)
    request.httpMethod = method
    for (name, value) in headers {
      request.setValue(value, forHTTPHeaderField: name)
    }
    if let json {
      request.httpBody = try json.data
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return try await send(request)
  }

  /// Sends the request as it is.
  public static func send(_ request: URLRequest) async throws -> Answer {
    let (body, response) = try await session.data(for: request, delegate: NoRedirects())
    guard let response = response as? HTTPURLResponse, let url = request.url else { throw URLError(.badServerResponse) }
    var headers: [String: String] = [:]
    for (name, value) in response.allHeaderFields {
      headers["\(name)".lowercased()] = "\(value)"
    }
    return Answer(
      method: request.httpMethod ?? "GET", url: url, status: response.statusCode, headers: headers, body: body)
  }

  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: configuration)
  }()

  /// An answer that redirects is the answer. Nothing follows it.
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

/// A user's bearer session on a test server: what the app holds after it redeems a login link.
public struct BearerSession: Sendable {
  /// The instance address, such as `http://localhost:50123`.
  public let instance: URL
  public let token: String
  public let userID: String

  public init(instance: URL, token: String, userID: String) {
    self.instance = instance
    self.token = token
    self.userID = userID
  }

  /// Sends a request as the user. The path is under `/api/v2`, as in the server's route table, and can have a
  /// query: `/lists?recipient_id=7`.
  public func send(_ method: String, _ path: String, json: JSON? = nil) async throws -> TestHTTP.Answer {
    guard let url = URL(string: instance.absoluteString + TestServer.apiPrefix + path) else { throw URLError(.badURL) }
    return try await TestHTTP.send(method, url, headers: ["Authorization": "Bearer \(token)"], json: json)
  }

  /// The JSON of a `GET` that must answer 200.
  public func get(_ path: String) async throws -> JSON {
    try await send("GET", path).expecting(200).json
  }

  /// The status of a `GET`: 200 for what the user can see, and 404 for what they can't.
  public func status(of path: String) async throws -> Int {
    try await send("GET", path).status
  }

  /// The JSON of a `POST` that must answer 200 or 201.
  @discardableResult
  public func post(_ path: String, _ json: JSON? = nil) async throws -> JSON {
    try await send("POST", path, json: json).expecting(200, 201).json
  }
}
