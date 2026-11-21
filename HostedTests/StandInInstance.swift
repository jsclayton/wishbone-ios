import Foundation
import Network
import Synchronization

/// A stand-in for an instance with nothing in it: a small HTTP server on the loopback that answers as the API does
/// for the version check and the versions, and counts the requests for the versions. Any other request gets a 404.
///
/// The hosted test bundle can't link `TestSupport`, so this is its own.
nonisolated final class StandInInstance: Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "StandInInstance")
  private let pulls = Mutex(0)

  /// The port it listens on.
  let port: UInt16

  /// Its address, to sign in to.
  var address: String { "http://127.0.0.1:\(port)" }

  /// How many times a device has asked it for the versions: once for each sync.
  var pullCount: Int {
    pulls.withLock { $0 }
  }

  /// Starts a stand-in on a free port of the loopback.
  static func start() async throws -> StandInInstance {
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
      listener.start(queue: DispatchQueue(label: "StandInInstance.start"))
    }
    return StandInInstance(listener: listener, port: port)
  }

  private init(listener: NWListener, port: UInt16) {
    self.listener = listener
    self.port = port
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
  }

  deinit {
    listener.cancel()
  }

  private func accept(_ connection: NWConnection) {
    connection.start(queue: queue)
    read(connection, Data())
  }

  /// Reads the request's head, and answers it. No request of these routes has a body.
  private func read(_ connection: NWConnection, _ received: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      var received = received
      if let data { received.append(data) }
      if let end = received.firstRange(of: Data("\r\n\r\n".utf8)) {
        let head = String(decoding: received[..<end.lowerBound], as: UTF8.self)
        connection.send(content: answer(to: head), completion: .contentProcessed { _ in connection.cancel() })
      } else if isComplete || error != nil {
        connection.cancel()
      } else {
        read(connection, received)
      }
    }
  }

  /// The answer to a request, by its head.
  private func answer(to head: String) -> Data {
    let lines = head.split(separator: "\r\n")
    let target = lines.first.map { $0.split(separator: " ").dropFirst().first.map(String.init) ?? "" } ?? ""
    let hasETag = lines.contains { $0.lowercased().hasPrefix("if-none-match:") }
    switch target {
    case "/api/v2/health":
      return Self.answer("200 OK", type: "application/json", body: #"{"status":"ok","version":"dev","commit":"0"}"#)
    case "/api/v2/versions":
      pulls.withLock { $0 += 1 }
      // Nothing is in it, and nothing changes: the versions of nothing, and a 304 once the device keeps the ETag.
      if hasETag { return Self.answer("304 Not Modified", headers: #"ETag: "v1""#) }
      return Self.answer("200 OK", type: "application/json", headers: #"ETag: "v1""#, body: #"{"data":[]}"#)
    default:
      return Self.answer(
        "404 Not Found", type: "application/problem+json",
        body: #"{"status":404,"title":"Not Found","code":"not_found","detail":""}"#)
    }
  }

  private static func answer(_ status: String, type: String? = nil, headers: String? = nil, body: String = "") -> Data {
    var head = "HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n"
    if let type { head += "Content-Type: \(type)\r\n" }
    if let headers { head += "\(headers)\r\n" }
    return Data((head + "\r\n" + body).utf8)
  }
}
