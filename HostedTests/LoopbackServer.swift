import Foundation
import Network
import Synchronization

/// A small HTTP server on the loopback, for the hosted tests: it reads each request whole, and answers it as its
/// handler says. `EnvelopeReceiver` stands in for Sentry with one, and `FakeInstance` for a Wishbone.
///
/// The hosted test bundle can't link `TestSupport`, so this is its own.
nonisolated final class LoopbackServer: Sendable {
  /// One request, as it arrived.
  struct Request: Sendable {
    let method: String
    /// The path and the query, such as `/api/v2/users?limit=200`.
    let target: String
    /// The headers, by their names in lower case.
    let headers: [String: String]
    /// The body, unzipped.
    let body: Data

    /// The path, without the query.
    var path: String {
      String(target.prefix { $0 != "?" })
    }
  }

  /// What the server does with a request.
  enum Reply: Sendable {
    /// An answer with this status, content type, and body.
    case answer(status: Int, contentType: String, body: Data)
    /// It closes the connection with no answer.
    case drop
    /// It never answers, and keeps the connection open until the server goes.
    case hold
  }

  typealias Handler = @Sendable (Request) -> Reply

  private struct State {
    var handler: Handler
    var requests: [Request] = []
    var held: [NWConnection] = []
  }

  private let listener: NWListener
  private let queue = DispatchQueue(label: "LoopbackServer")
  private let state: Mutex<State>

  /// The port it listens on.
  let port: UInt16

  /// Starts a server on a free port of the loopback.
  static func start(_ handler: @escaping Handler) async throws -> LoopbackServer {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
    let listener = try NWListener(using: parameters)
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      let resumed = Mutex(false)
      listener.stateUpdateHandler = { state in
        let value: Result<UInt16, Error>? =
          switch state {
          case .ready: listener.port.map { .success($0.rawValue) }
          case .failed(let error): .failure(error)
          default: nil
          }
        guard let value,
          resumed.withLock({ done in
            defer { done = true }; return !done
          })
        else { return }
        continuation.resume(with: value)
      }
      listener.newConnectionHandler = { _ in }
      listener.start(queue: DispatchQueue(label: "LoopbackServer.start"))
    }
    return LoopbackServer(listener: listener, port: port, handler: handler)
  }

  private init(listener: NWListener, port: UInt16, handler: @escaping Handler) {
    self.listener = listener
    self.port = port
    state = Mutex(State(handler: handler))
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
  }

  deinit {
    listener.cancel()
    for connection in state.withLock({ $0.held }) { connection.cancel() }
  }

  /// What the server does with the next requests.
  func handle(with handler: @escaping Handler) {
    state.withLock { $0.handler = handler }
  }

  /// Every request that it has read, in the order they came.
  var requests: [Request] {
    state.withLock { $0.requests }
  }

  private func accept(_ connection: NWConnection) {
    connection.start(queue: queue)
    read(connection, Data())
  }

  /// Reads the request: its head, then as many bytes of body as its `Content-Length` says.
  private func read(_ connection: NWConnection, _ received: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      var received = received
      if let data { received.append(data) }
      if let request = Self.request(in: received) {
        let handler = state.withLock { state in
          state.requests.append(request)
          return state.handler
        }
        reply(handler(request), on: connection)
      } else if isComplete || error != nil {
        connection.cancel()
      } else {
        read(connection, received)
      }
    }
  }

  private func reply(_ reply: Reply, on connection: NWConnection) {
    switch reply {
    case .answer(let status, let contentType, let body):
      let head =
        "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\n"
        + "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
      connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    case .drop:
      connection.cancel()
    case .hold:
      state.withLock { $0.held.append(connection) }
    }
  }

  /// The request in the data, unzipped, or nil while more of it is to come.
  private static func request(in data: Data) -> Request? {
    guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
    let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).split(separator: "\r\n")
    guard let first = lines.first else { return nil }
    let requestLine = first.split(separator: " ")
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    let length = Int(headers["content-length"] ?? "") ?? 0
    let body = data[end.upperBound...]
    guard body.count >= length else { return nil }
    var bytes = Data(body.prefix(length))
    if headers["content-encoding"]?.contains("gzip") == true { bytes = gunzip(bytes) ?? bytes }
    return Request(
      method: requestLine.first.map(String.init) ?? "",
      target: requestLine.dropFirst().first.map(String.init) ?? "",
      headers: headers, body: bytes)
  }

  /// Unzips a gzip body: its header, then raw DEFLATE, which is what the Compression framework's zlib reads.
  private static func gunzip(_ data: Data) -> Data? {
    let bytes = [UInt8](data)
    guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }
    let flags = bytes[3]
    var start = 10
    if flags & 0x04 != 0 { start += 2 + Int(bytes[start]) + Int(bytes[start + 1]) << 8 }
    if flags & 0x08 != 0 { start = (bytes[start...].firstIndex(of: 0) ?? start) + 1 }
    if flags & 0x10 != 0 { start = (bytes[start...].firstIndex(of: 0) ?? start) + 1 }
    if flags & 0x02 != 0 { start += 2 }
    let deflated = Data(bytes[start..<(bytes.count - 8)])
    return try? (deflated as NSData).decompressed(using: .zlib) as Data
  }
}

/// A stand-in for a Wishbone instance: the API's answers, as each test's handler gives them, at
/// `http://127.0.0.1:<port>`.
nonisolated final class FakeInstance: Sendable {
  private let server: LoopbackServer

  /// The instance address.
  var address: String { "http://127.0.0.1:\(server.port)" }

  private init(server: LoopbackServer) {
    self.server = server
  }

  /// Starts an instance whose answer to each request under `/api/v2` is the handler's, by the path under it.
  static func start(_ handler: @escaping @Sendable (_ path: String) -> LoopbackServer.Reply) async throws
    -> FakeInstance
  {
    let server = try await LoopbackServer.start { request in
      handler(String(request.path.dropFirst("/api/v2".count)))
    }
    return FakeInstance(server: server)
  }

  /// Every request that it has read.
  var requests: [LoopbackServer.Request] {
    server.requests
  }

  /// An answer of the API with a JSON body.
  static func json(_ status: Int, _ text: String) -> LoopbackServer.Reply {
    .answer(status: status, contentType: "application/json", body: Data(text.utf8))
  }

  /// A problem of the API: problem+json with a code.
  static func problem(_ status: Int, code: String) -> LoopbackServer.Reply {
    .answer(
      status: status, contentType: "application/problem+json",
      body: Data(#"{"status":\#(status),"title":"Refused","code":"\#(code)","detail":"Robin's secret"}"#.utf8))
  }
}
