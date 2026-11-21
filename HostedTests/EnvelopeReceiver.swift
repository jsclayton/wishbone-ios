import Foundation
import Synchronization

/// A stand-in for Sentry: a small HTTP server on the loopback that keeps each envelope that the SDK sends it. A test
/// gives the SDK a DSN for it, so what the SDK sends is checked at the envelope, as it would leave the device.
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

    /// The whole envelope as it arrived, unzipped: its header, and every item. Sentry's JSON writes `/` as `\/`, so
    /// the text has each one as `/` again: a check for a path or a zone in the text must be able to fail.
    let text: String

    /// The events of the envelope.
    var events: [[String: Any]] {
      items.filter { $0.type == "event" }.compactMap(\.json)
    }
  }

  /// What the receiver keeps: its mode, and the body of each envelope. The server's handler shares it.
  private final class Store: Sendable {
    let mode = Mutex(Mode.answer)
    let bodies = Mutex([Data]())
  }

  private let server: LoopbackServer
  private let store: Store

  /// The port it listens on.
  var port: UInt16 { server.port }

  /// A DSN that sends to the receiver.
  var dsn: String { "http://public@127.0.0.1:\(port)/1" }

  /// Starts a receiver on a free port of the loopback.
  static func start() async throws -> EnvelopeReceiver {
    let store = Store()
    let server = try await LoopbackServer.start { request in
      guard store.mode.withLock({ $0 }) == .answer else { return .drop }
      store.bodies.withLock { $0.append(request.body) }
      return .answer(status: 200, contentType: "application/json", body: Data("{}".utf8))
    }
    return EnvelopeReceiver(server: server, store: store)
  }

  private init(server: LoopbackServer, store: Store) {
    self.server = server
    self.store = store
  }

  /// What the receiver does with the next requests.
  func set(_ mode: Mode) {
    store.mode.withLock { $0 = mode }
  }

  /// Every envelope that it has kept, in the order they came.
  var envelopes: [Envelope] {
    store.bodies.withLock { $0 }.map(Self.envelope)
  }

  /// Every event that it has kept.
  var events: [[String: Any]] {
    envelopes.flatMap(\.events)
  }

  /// The items of an envelope: a header line, then for each item its header line and its payload.
  static func envelope(_ body: Data) -> Envelope {
    let text = String(decoding: body, as: UTF8.self).replacingOccurrences(of: #"\/"#, with: "/")
    var lines = body.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { Data($0) }
    guard !lines.isEmpty else { return Envelope(items: [], text: text) }
    lines.removeFirst()
    var items: [Envelope.Item] = []
    while lines.count >= 2 {
      let header = (try? JSONSerialization.jsonObject(with: lines.removeFirst())) as? [String: Any] ?? [:]
      items.append(Envelope.Item(header: header, payload: lines.removeFirst()))
    }
    return Envelope(items: items, text: text)
  }
}
