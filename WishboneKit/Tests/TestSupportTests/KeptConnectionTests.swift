import Foundation
import Network
import Synchronization
import TestSupport
import Testing

/// A server can close a kept-alive connection just as the client sends the next request on it. The test server
/// does: it resets a connection that has carried no request for 10 seconds (its `ReadHeaderTimeout`), and a
/// reverse proxy closes an idle one. `URLSession` sends a `GET` again on a new connection, but fails a `POST`,
/// `PATCH`, `PUT` or `DELETE` with `networkConnectionLost`. So the harness never sends a request on a connection
/// that an earlier request used.
///
/// The small server below closes a connection that has carried a request, when the next one comes, because that
/// is the moment it can make every time. The test server's case, a connection that carried no request, takes a
/// wait of 10 seconds. A new connection for each request rules out both.
@Suite("A kept connection that the server closes", .timeLimit(.minutes(1)))
struct KeptConnectionTests {
  @Test("Each request of the harness goes on a new connection, so a closed kept connection fails none")
  func harnessUsesNewConnections() async throws {
    let server = try await ClosesKeptConnections()
    for method in ["POST", "PATCH", "PUT", "DELETE", "POST"] {
      try await TestHTTP.send(method, server.url, json: ["n": 1]).expecting(200)
    }
    #expect(server.closedOnReuse == 0)
  }

  @Test("Each request that the conditioner passes through goes on a new connection to the server")
  func conditionerUsesNewConnections() async throws {
    let server = try await ClosesKeptConnections()
    let conditioner = try await NetworkConditioner(to: server.address)
    for method in ["POST", "PATCH", "PUT", "DELETE", "POST"] {
      try await TestHTTP.send(method, conditioner.address.appending(path: "a"), json: ["n": 1]).expecting(200)
    }
    #expect(conditioner.requests.count == 5)
    #expect(server.closedOnReuse == 0)
  }
}

/// A server that keeps each connection open after its first answer, and closes it, with no answer, when a second
/// request comes on it. It is the moment when a server closes a kept connection just as the client reuses it,
/// every time.
private final class ClosesKeptConnections: Sendable {
  let address: URL
  var url: URL { address.appending(path: "a") }

  /// How many requests came on a connection that had already carried one.
  var closedOnReuse: Int { connections.closed.withLock { $0 } }

  private let listener: NWListener
  private let connections = Connections()

  init() async throws {
    let parameters = NWParameters.tcp
    parameters.acceptLocalOnly = true
    let listener = try NWListener(using: parameters, on: .any)
    let connections = connections
    let started = Mutex(false)
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      listener.stateUpdateHandler = { [weak listener] state in
        let result: Result<UInt16, any Error>
        switch state {
        case .ready: result = .success(listener?.port?.rawValue ?? 0)
        case .failed(let error): result = .failure(error)
        default: return
        }
        let isFirst = started.withLock { started in
          defer { started = true }
          return !started
        }
        if isFirst { continuation.resume(with: result) }
      }
      listener.newConnectionHandler = { connection in connections.accept(connection) }
      listener.start(queue: connections.queue)
    }
    guard let address = URL(string: "http://localhost:\(port)") else { throw URLError(.badURL) }
    self.listener = listener
    self.address = address
  }

  deinit {
    listener.cancel()
  }

  private final class Connections: Sendable {
    let closed = Mutex(0)
    let queue = DispatchQueue(label: "wishbone.closes-kept-connections")

    func accept(_ connection: NWConnection) {
      connection.start(queue: queue)
      serve(connection, buffer: Data(), answered: 0)
    }

    /// Reads requests from the connection: it answers the first, and closes the connection at the start of the
    /// next.
    private func serve(_ connection: NWConnection, buffer: Data, answered: Int) {
      if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
        if answered > 0 {
          closed.withLock { $0 += 1 }
          connection.cancel()
          return
        }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).lowercased()
        let length =
          head.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
          .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        if buffer.count - end.upperBound >= length {
          let rest = Data(buffer[(end.upperBound + length)...])
          let answer = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
          connection.send(
            content: Data(answer.utf8),
            completion: .contentProcessed { _ in self.serve(connection, buffer: rest, answered: answered + 1) })
          return
        }
      }
      connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, _, error in
        guard let data, !data.isEmpty, error == nil else {
          connection.cancel()
          return
        }
        self.serve(connection, buffer: buffer + data, answered: answered)
      }
    }
  }
}
