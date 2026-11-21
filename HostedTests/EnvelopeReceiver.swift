import Foundation
import Network
import Synchronization

/// A stand-in for Sentry: a small HTTP server on the loopback that keeps each envelope that the SDK sends it. A test
/// gives the SDK a DSN for it, so what the SDK sends is checked at the envelope, as it would leave the device.
///
/// The hosted test bundle can't link `TestSupport`, so this is its own.
nonisolated final class EnvelopeReceiver: Sendable {
  /// What the receiver does with a request.
  enum Mode {
    /// It keeps the envelope, and answers 200.
    case answer
    /// It closes the connection with no answer, so the SDK keeps the envelope to send later.
    case drop
  }

  /// One envelope: its items, each with its header and its payload.
  struct Envelope {
    struct Item {
      let header: [String: Any]
      let payload: Data

      var type: String? { header["type"] as? String }

      /// The payload as a JSON object, for an event.
      var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
      }
    }

    let items: [Item]

    /// The events of the envelope.
    var events: [[String: Any]] {
      items.filter { $0.type == "event" }.compactMap(\.json)
    }
  }

  private let listener: NWListener
  private let queue = DispatchQueue(label: "EnvelopeReceiver")
  private let state = Mutex<(mode: Mode, bodies: [Data])>((.answer, []))

  /// The port it listens on.
  let port: UInt16

  /// A DSN that sends to the receiver.
  var dsn: String { "http://public@127.0.0.1:\(port)/1" }

  /// Starts a receiver on a free port of the loopback.
  static func start() async throws -> EnvelopeReceiver {
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
      listener.start(queue: DispatchQueue(label: "EnvelopeReceiver.start"))
    }
    return EnvelopeReceiver(listener: listener, port: port)
  }

  private init(listener: NWListener, port: UInt16) {
    self.listener = listener
    self.port = port
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
  }

  deinit {
    listener.cancel()
  }

  /// What the receiver does with the next requests.
  func set(_ mode: Mode) {
    state.withLock { $0.mode = mode }
  }

  /// Every envelope that it has kept, in the order they came.
  var envelopes: [Envelope] {
    state.withLock { $0.bodies }.map(Self.envelope)
  }

  /// Every event that it has kept.
  var events: [[String: Any]] {
    envelopes.flatMap(\.events)
  }

  private func accept(_ connection: NWConnection) {
    connection.start(queue: queue)
    if state.withLock({ $0.mode }) == .drop {
      connection.cancel()
      return
    }
    read(connection, Data())
  }

  /// Reads the request: its head, then as many bytes of body as its `Content-Length` says.
  private func read(_ connection: NWConnection, _ received: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      var received = received
      if let data { received.append(data) }
      if let request = Self.request(in: received) {
        state.withLock { $0.bodies.append(request) }
        let answer =
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
        connection.send(content: Data(answer.utf8), completion: .contentProcessed { _ in connection.cancel() })
      } else if isComplete || error != nil {
        connection.cancel()
      } else {
        read(connection, received)
      }
    }
  }

  /// The body of a whole request, unzipped, or nil while more of it is to come.
  private static func request(in data: Data) -> Data? {
    guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
    let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).lowercased()
    var length = 0
    var isZipped = false
    for line in head.split(separator: "\r\n") {
      if line.hasPrefix("content-length:") {
        length = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0
      }
      if line.hasPrefix("content-encoding:"), line.contains("gzip") { isZipped = true }
    }
    let body = data[end.upperBound...]
    guard body.count >= length else { return nil }
    let bytes = Data(body.prefix(length))
    return isZipped ? gunzip(bytes) ?? bytes : bytes
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

  /// The items of an envelope: a header line, then for each item its header line and its payload.
  private static func envelope(_ body: Data) -> Envelope {
    var lines = body.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { Data($0) }
    guard !lines.isEmpty else { return Envelope(items: []) }
    lines.removeFirst()
    var items: [Envelope.Item] = []
    while lines.count >= 2 {
      let header = (try? JSONSerialization.jsonObject(with: lines.removeFirst())) as? [String: Any] ?? [:]
      items.append(Envelope.Item(header: header, payload: lines.removeFirst()))
    }
    return Envelope(items: items)
  }
}
