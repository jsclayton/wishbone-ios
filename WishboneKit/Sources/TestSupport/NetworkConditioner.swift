import Foundation
import Network
import Synchronization

/// What a real server can't do: no network, an answer that is late, and an answer that the server never gives.
///
/// The conditioner is a small HTTP server on this machine, in front of a test server. The code under test uses the
/// conditioner's address as its instance address, so it needs no seam of its own. Every request passes through to
/// the real server, unless a test tells the conditioner otherwise. See "What a real server can't do" in
/// `docs/development.md`.
///
/// It stops when its last holder goes.
///
/// What it is not, for the code that it tests:
/// - A drop closes the connection with no answer. `URLSession` reports that as a `URLError` such as
///   `networkConnectionLost` or `cannotConnectToHost`, and never as `notConnectedToInternet`. So a rule for an
///   unreachable instance must not depend on one code.
/// - Every answer has `Connection: close`, so each request is on a connection of its own.
/// - Response headers with one name come back as one header, joined with commas. An answer has no
///   `Content-Encoding`: its body comes back as it is after the coding.
public final class NetworkConditioner: Sendable {
  /// The conditioner's address, such as `http://localhost:50124`. Use it in place of the server's address.
  public let address: URL

  /// The address of the real server behind it.
  public let server: URL

  private let core: Core

  /// How the conditioner takes a connection from the code under test.
  public enum TLS: Sendable {
    /// Plain HTTP.
    case none

    /// HTTPS, with a self-signed certificate that no device trusts, as an instance has whose certificate comes
    /// from a private certificate authority that the device doesn't have. `URLSession` refuses the handshake, so
    /// no request reaches the conditioner. Only on macOS: the conditioner makes the certificate with `openssl`.
    case untrustedCertificate
  }

  /// Starts a conditioner in front of the server at `server`, on a free port. Its address is `https` with `tls`.
  public init(to server: URL, tls: TLS = .none) async throws {
    core = Core(server: server)
    let parameters: NWParameters
    switch tls {
    case .none:
      parameters = .tcp
    case .untrustedCertificate:
      let options = NWProtocolTLS.Options()
      sec_protocol_options_set_local_identity(options.securityProtocolOptions, try UntrustedCertificate.identity())
      parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
    }
    let port = try await core.start(with: parameters)
    let scheme = tls == .none ? "http" : "https"
    guard let address = URL(string: "\(scheme)://localhost:\(port)") else { throw URLError(.badURL) }
    self.address = address
    self.server = server
  }

  deinit {
    core.stop()
  }

  /// Stops the conditioner. The last holder's release does this too.
  public func stop() {
    core.stop()
  }

  /// A URL at the conditioner for a path under `/api/v2`, such as `/health`. The path has no query.
  public func url(_ path: String) -> URL {
    address.appending(path: TestServer.apiPrefix + path)
  }

  /// The same URL at the conditioner's address. A login link of the server then signs the app in through the
  /// conditioner.
  public func rerouted(_ url: URL) -> URL {
    var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    parts?.scheme = address.scheme
    parts?.host = address.host()
    parts?.port = address.port
    return parts?.url ?? url
  }

  /// Every request that reached the conditioner, oldest first, whatever became of it: passed through, held, or
  /// answered with a canned answer. A request that a drop refused is not here: it never arrived.
  public var requests: [SeenRequest] {
    core.requests
  }

  /// A request as the conditioner saw it.
  public struct SeenRequest: Sendable {
    public let method: String

    /// The path, and the query when there is one.
    public let target: String

    /// The headers, with their names in lower case.
    public let headers: [String: String]

    /// The body, as the conditioner read it.
    public let body: Data

    /// Whether the request is on the route.
    public func isOn(_ route: Route) -> Bool {
      route.matches(method: method, target: target)
    }
  }

  /// Drops everything, as a device with no network does: every request fails with no answer, and the requests in
  /// flight are cut off. A request that already reached the server still takes effect there. A request that was
  /// held before the server never reaches it, however its hold ends and whenever the network comes back.
  public func dropEverything() {
    core.dropEverything()
  }

  /// Holds each request that matches the route, until the test releases the hold.
  ///
  /// At `.answer`, the request goes to the server at once, and the conditioner holds the server's answer: the
  /// change is made, and the answer is in flight. At `.request`, the request waits, and reaches the server after
  /// the release.
  public func hold(_ route: Route, at point: Hold.Point = .answer) -> Hold {
    let hold = Hold(point: point)
    core.add(.init(route: route, action: .hold(hold)))
    return hold
  }

  /// Answers each request that matches the route with the canned answer. The request never reaches the server.
  public func answer(_ route: Route, with answer: CannedAnswer) {
    core.add(.init(route: route, action: .answer(answer)))
  }

  /// Closes the connection of the next `count` requests that match the route, with no answer, as a server or a
  /// reverse proxy does to a kept connection that it has just closed when the next request comes on it. The
  /// request never reaches the server. A request after those passes through, unless another rule says otherwise.
  ///
  /// `URLSession` reports the lost connection to the code under test as `networkConnectionLost`.
  public func loseConnection(_ route: Route, count: Int = 1) {
    core.add(.init(route: route, action: .lose(Losses(count))))
  }

  /// Goes back to passing every request through: it stops dropping, releases every hold, and forgets every canned
  /// answer and every lost connection still to come.
  public func passEverything() {
    core.passEverything()
  }

  // MARK: - Routes, holds, and canned answers

  /// A route of the API: a method, and a path under `/api/v2` as the server's route table writes it. A part in
  /// braces matches any one part of a path, so `/items/{id}/gifts` matches `/api/v2/items/12/gifts`.
  public struct Route: Sendable, Hashable {
    public let method: String
    public let path: String

    public init(_ method: String, _ path: String) {
      self.method = method.uppercased()
      self.path = path
    }

    /// Whether a request with the method and the target (a path, and perhaps a query) is on the route.
    public func matches(method: String, target: String) -> Bool {
      guard method.uppercased() == self.method else { return false }
      let requested = target.prefix { $0 != "?" }.split(separator: "/", omittingEmptySubsequences: false)
      let pattern = (TestServer.apiPrefix + path).split(separator: "/", omittingEmptySubsequences: false)
      guard requested.count == pattern.count else { return false }
      return zip(pattern, requested).allSatisfy { pattern, requested in
        pattern.hasPrefix("{") && pattern.hasSuffix("}") ? !requested.isEmpty : pattern == requested
      }
    }
  }

  /// A hold on the requests of one route. The test releases it.
  ///
  /// It holds every request on the route that comes before the release, and `waitUntilHeld()` returns when it
  /// holds the first one. A released hold is over: to hold a later request, make a new hold.
  public final class Hold: Sendable {
    /// Where a request is held.
    public enum Point: Sendable {
      /// Before it reaches the server.
      case request
      /// After the server answered, with the answer in flight.
      case answer
    }

    public let point: Point

    private struct State {
      var held = 0
      var isReleased = false
      var nextWaiter = 0
      /// The callers of `waitUntilHeld()` that still wait, each by its own number.
      var arrivals: [Int: CheckedContinuation<Void, Never>] = [:]
      var releases: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    init(point: Point) {
      self.point = point
    }

    /// Whether the test has released the hold.
    var isReleased: Bool {
      state.withLock { $0.isReleased }
    }

    /// Returns when the conditioner holds a request, or has held one. At `.answer`, the server has answered it by
    /// then. A test waits here, and never for a length of time.
    ///
    /// It also returns when its task is cancelled. So the time limit of a test ends a wait for a request that
    /// never comes, and the test fails by its name.
    public func waitUntilHeld() async {
      let waiter = state.withLock { state in
        defer { state.nextWaiter += 1 }
        return state.nextWaiter
      }
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          let isOver = state.withLock { state in
            // A cancel that came before this point found no one to wake.
            if state.held > 0 || Task.isCancelled { return true }
            state.arrivals[waiter] = continuation
            return false
          }
          if isOver { continuation.resume() }
        }
      } onCancel: {
        state.withLock { $0.arrivals.removeValue(forKey: waiter) }?.resume()
      }
    }

    /// Lets the held requests go on, and stops holding.
    public func release() {
      let waiting = state.withLock { state in
        state.isReleased = true
        defer { state.releases = [] }
        return state.releases
      }
      waiting.forEach { $0.resume() }
    }

    /// Holds the caller, a request on the hold's route, until the release.
    func wait() async {
      await withCheckedContinuation { continuation in
        let (arrivals, isReleased) = state.withLock { state in
          state.held += 1
          defer { state.arrivals = [:] }
          if !state.isReleased { state.releases.append(continuation) }
          return (Array(state.arrivals.values), state.isReleased)
        }
        arrivals.forEach { $0.resume() }
        if isReleased { continuation.resume() }
      }
    }
  }

  /// How many more requests on a route lose their connection.
  final class Losses: Sendable {
    private let left: Mutex<Int>

    init(_ count: Int) {
      left = Mutex(count)
    }

    var isOver: Bool {
      left.withLock { $0 <= 0 }
    }

    /// Takes one loss for a request.
    func take() {
      left.withLock { $0 = max($0 - 1, 0) }
    }
  }

  /// An answer that the conditioner gives in the server's place.
  public struct CannedAnswer: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
      self.status = status
      self.headers = headers
      self.body = body
    }

    /// An answer with a JSON body.
    public static func json(_ status: Int, _ json: JSON, contentType: String = "application/json") throws
      -> CannedAnswer
    {
      CannedAnswer(status: status, headers: ["Content-Type": contentType], body: try json.data)
    }

    /// An error in the server's shape: problem+json with a `code`, such as a 410 `api_version_removed`.
    public static func problem(_ status: Int, code: String, detail: String = "") throws -> CannedAnswer {
      let title = HTTPURLResponse.localizedString(forStatusCode: status).capitalized
      let body: JSON = [
        "status": .number(Double(status)), "title": .string(title), "code": .string(code), "detail": .string(detail),
      ]
      return try json(status, body, contentType: "application/problem+json")
    }
  }
}

// MARK: - The proxy

extension NetworkConditioner {
  fileprivate struct Rule: Sendable {
    enum Action: Sendable {
      case hold(Hold)
      case answer(CannedAnswer)
      case lose(Losses)
    }

    let route: Route
    let action: Action

    /// A hold that the test released is over, and so are losses that have all happened. Neither must hide an
    /// older rule for its route.
    var isInForce: Bool {
      switch action {
      case .hold(let hold): !hold.isReleased
      case .answer: true
      case .lose(let losses): !losses.isOver
      }
    }
  }

  /// The listener, the open connections, and what the test asked for.
  fileprivate final class Core: Sendable {
    private struct State {
      var isDropping = false
      /// The newest rule is first, so it wins.
      var rules: [Rule] = []
      var connections: [ObjectIdentifier: NWConnection] = [:]
      var listener: NWListener?
      var requests: [SeenRequest] = []
      /// The session of each request that is on its way to the server, or back. A stop cancels them.
      var forwards: [ObjectIdentifier: URLSession] = [:]
      var isStopped = false
    }

    var requests: [SeenRequest] {
      state.withLock { $0.requests }
    }

    private let server: URL
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "wishbone.network-conditioner")

    init(server: URL) {
      self.server = server
    }

    /// Starts to listen on a free port of this machine, and returns the port.
    func start(with parameters: NWParameters) async throws -> Int {
      // Only this machine can connect.
      parameters.acceptLocalOnly = true
      let listener = try NWListener(using: parameters, on: .any)
      listener.newConnectionHandler = { [self] connection in accept(connection) }
      state.withLock { $0.listener = listener }
      let started = Mutex(false)
      return try await withCheckedThrowingContinuation { continuation in
        listener.stateUpdateHandler = { [weak listener] state in
          let result: Result<Int, any Error>
          switch state {
          case .ready: result = .success(Int(listener?.port?.rawValue ?? 0))
          case .failed(let error): result = .failure(error)
          case .cancelled: result = .failure(CancellationError())
          default: return
          }
          // The handler runs again for each later state. Only the first result is the start's.
          let isFirst = started.withLock { started in
            defer { started = true }
            return !started
          }
          if isFirst { continuation.resume(with: result) }
        }
        listener.start(queue: queue)
      }
    }

    func stop() {
      let (listener, connections, forwards) = state.withLock { state in
        defer {
          state.listener = nil
          state.connections = [:]
          state.forwards = [:]
          state.isStopped = true
        }
        return (state.listener, Array(state.connections.values), Array(state.forwards.values))
      }
      listener?.newConnectionHandler = nil
      listener?.cancel()
      connections.forEach { $0.cancel() }
      releaseHolds()
      forwards.forEach { $0.invalidateAndCancel() }
    }

    func add(_ rule: Rule) {
      state.withLock { $0.rules.insert(rule, at: 0) }
    }

    func dropEverything() {
      let connections = state.withLock { state in
        state.isDropping = true
        defer { state.connections = [:] }
        return Array(state.connections.values)
      }
      connections.forEach { $0.cancel() }
    }

    func passEverything() {
      releaseHolds()
      state.withLock { state in
        state.isDropping = false
        state.rules = []
      }
    }

    private func releaseHolds() {
      for rule in state.withLock({ $0.rules }) {
        if case .hold(let hold) = rule.action { hold.release() }
      }
    }

    private func accept(_ connection: NWConnection) {
      let isDropping = state.withLock { state in
        if !state.isDropping { state.connections[ObjectIdentifier(connection)] = connection }
        return state.isDropping
      }
      connection.start(queue: queue)
      guard !isDropping else {
        connection.cancel()
        return
      }
      Task {
        await serve(connection)
        connection.cancel()
        state.withLock { _ = $0.connections.removeValue(forKey: ObjectIdentifier(connection)) }
      }
    }

    /// Reads one request, and answers it. Each connection carries one request.
    private func serve(_ connection: NWConnection) async {
      do {
        var reader = HTTPReader(connection: connection)
        guard let request = try await reader.request() else { return }
        let rule = state.withLock { state -> Rule? in
          var headers: [String: String] = [:]
          for (name, value) in request.headers {
            headers[name.lowercased()] = value
          }
          state.requests.append(
            SeenRequest(method: request.method, target: request.target, headers: headers, body: request.body))
          let rule = state.rules.first {
            $0.isInForce && $0.route.matches(method: request.method, target: request.target)
          }
          // A loss is taken under the lock that found it in force, so two requests at once never both take the last.
          if case .lose(let losses) = rule?.action { losses.take() }
          return rule
        }
        let answer: CannedAnswer
        switch rule?.action {
        case .lose:
          // The connection closes with no answer when `serve` returns.
          return
        case .answer(let canned):
          answer = canned
        case .hold(let hold) where hold.point == .request:
          await hold.wait()
          // A request that was still on its way when the network went never reaches the server, even when the
          // network is back by now.
          guard isOpen(connection) else { return }
          answer = try await forward(request)
        case .hold(let hold):
          answer = try await forward(request)
          await hold.wait()
        case nil:
          answer = try await forward(request)
        }
        // An answer that comes back after the network went must not arrive.
        guard isOpen(connection) else { return }
        try await send(answer, for: request, on: connection)
      } catch {
        // The client went away, or the server could not be reached. The client sees a connection with no answer.
      }
    }

    /// Whether the connection is still the conditioner's. A drop, and a stop, take every open connection away for
    /// good. So what happens to a request goes by its own connection, not by what the conditioner does now.
    private func isOpen(_ connection: NWConnection) -> Bool {
      state.withLock { $0.connections[ObjectIdentifier(connection)] != nil }
    }

    /// Sends the request to the real server, and returns its answer.
    ///
    /// The request goes on a new connection, to `127.0.0.1` and with `Connection: close`, as each request of
    /// `TestHTTP` does (see `TestHTTP.alone(_:)`), and for the same reason: the server can close a kept connection
    /// just as the next request goes on it. The code under test would then see a lost connection that no real
    /// network caused.
    private func forward(_ request: HTTPReader.Request) async throws -> CannedAnswer {
      guard let url = URL(string: server.absoluteString + request.target) else { throw URLError(.badURL) }
      var forwarded = URLRequest(url: url)
      forwarded.httpMethod = request.method
      for (name, value) in request.headers where !Self.perConnection.contains(name.lowercased()) {
        forwarded.addValue(value, forHTTPHeaderField: name)
      }
      if !request.body.isEmpty { forwarded.httpBody = request.body }
      let session = TestHTTP.newSession()
      let isStopped = state.withLock { state in
        if !state.isStopped { state.forwards[ObjectIdentifier(session)] = session }
        return state.isStopped
      }
      defer {
        state.withLock { _ = $0.forwards.removeValue(forKey: ObjectIdentifier(session)) }
        session.finishTasksAndInvalidate()
      }
      guard !isStopped else { throw CancellationError() }
      let (body, response) = try await session.data(for: TestHTTP.alone(forwarded), delegate: NoRedirects())
      guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
      var headers: [String: String] = [:]
      for (name, value) in response.allHeaderFields {
        headers["\(name)"] = "\(value)"
      }
      return CannedAnswer(status: response.statusCode, headers: headers, body: body)
    }

    private func send(_ answer: CannedAnswer, for request: HTTPReader.Request, on connection: NWConnection) async throws
    {
      let reason = HTTPURLResponse.localizedString(forStatusCode: answer.status).capitalized
      var head = "HTTP/1.1 \(answer.status) \(reason)\r\n"
      // URLSession gives the body as it is after any content coding, so the coding's header would be wrong.
      for (name, value) in answer.headers.sorted(by: { $0.key < $1.key })
      where !Self.perConnection.contains(name.lowercased()) && name.lowercased() != "content-encoding" {
        head += "\(name): \(value)\r\n"
      }
      let hasNoBody = request.method == "HEAD" || answer.status == 204 || answer.status == 304
      if !hasNoBody { head += "Content-Length: \(answer.body.count)\r\n" }
      head += "Connection: close\r\n\r\n"
      let message = Data(head.utf8) + (hasNoBody ? Data() : answer.body)
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        connection.send(
          content: message,
          contentContext: .finalMessage,
          isComplete: true,
          completion: .contentProcessed { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
          }
        )
      }
    }

    /// The headers that belong to one connection, and never pass through. The conditioner writes its own.
    private static let perConnection: Set<String> = [
      "connection", "content-length", "host", "keep-alive", "proxy-connection", "te", "trailer", "transfer-encoding",
      "upgrade",
    ]
  }

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

/// Reads an HTTP/1.1 request from a connection.
private struct HTTPReader {
  struct Request {
    let method: String
    /// The path, and the query when there is one.
    let target: String
    let headers: [(name: String, value: String)]
    let body: Data

    func header(_ name: String) -> String? {
      headers.first { $0.name.lowercased() == name }?.value
    }
  }

  struct Malformed: Error {}

  let connection: NWConnection
  private var buffer = Data()

  init(connection: NWConnection) {
    self.connection = connection
  }

  /// The next request. Nil when the client closed the connection before it sent one.
  mutating func request() async throws -> Request? {
    guard let head = try await take(through: Data("\r\n\r\n".utf8)) else { return nil }
    let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n").filter { !$0.isEmpty }
    let start = (lines.first ?? "").split(separator: " ")
    guard start.count == 3 else { throw Malformed() }
    let headers = lines.dropFirst().compactMap { line -> (name: String, value: String)? in
      guard let colon = line.firstIndex(of: ":") else { return nil }
      return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }
    var request = Request(method: String(start[0]), target: String(start[1]), headers: headers, body: Data())
    if request.header("transfer-encoding")?.lowercased().contains("chunked") == true {
      request = Request(method: request.method, target: request.target, headers: headers, body: try await chunkedBody())
    } else if let length = request.header("content-length").flatMap(Int.init), length > 0 {
      request = Request(method: request.method, target: request.target, headers: headers, body: try await take(length))
    }
    return request
  }

  private mutating func chunkedBody() async throws -> Data {
    var body = Data()
    let lineEnd = Data("\r\n".utf8)
    while true {
      guard let line = try await take(through: lineEnd) else { throw Malformed() }
      let digits = String(decoding: line, as: UTF8.self).prefix { $0.isHexDigit }
      guard let size = Int(digits, radix: 16) else { throw Malformed() }
      if size == 0 {
        // The trailers end with an empty line.
        while let trailer = try await take(through: lineEnd), trailer.count > lineEnd.count {}
        return body
      }
      body.append(try await take(size))
      _ = try await take(lineEnd.count)
    }
  }

  /// Takes the bytes up to the end of the first `mark`. Nil when the connection ends first.
  private mutating func take(through mark: Data) async throws -> Data? {
    while true {
      if let range = buffer.range(of: mark) {
        let taken = buffer.subdata(in: buffer.startIndex..<range.upperBound)
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        return taken
      }
      guard try await fill() else { return nil }
    }
  }

  private mutating func take(_ count: Int) async throws -> Data {
    while buffer.count < count {
      guard try await fill() else { throw Malformed() }
    }
    let taken = buffer.prefix(count)
    buffer.removeFirst(count)
    return Data(taken)
  }

  /// Reads more from the connection. False when the connection has ended.
  private mutating func fill() async throws -> Bool {
    let connection = connection
    let more: Data? = try await withCheckedThrowingContinuation { continuation in
      connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, _, error in
        if let data, !data.isEmpty {
          continuation.resume(returning: data)
        } else if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: nil)
        }
      }
    }
    guard let more else { return false }
    buffer.append(more)
    return true
  }
}
