import Darwin
import Foundation
import Synchronization
import TestSupport
import Testing

/// A listening socket holds the connections that it has not accepted yet in its listen queue, which this machine
/// caps at `kern.ipc.somaxconn`: 128 on macOS. A connection that comes when the queue is full is reset, and
/// `URLSession` fails its request with `networkConnectionLost` at once, a `GET` too, because the connection is new.
/// The test server accepts late on a busy machine, so a test that sends more requests at once than the queue
/// holds, such as 200 users for a group of more than one page, would fail on something that it doesn't test. So the
/// harness keeps few of its requests in flight at once.
@Suite("A listen queue that is full", .timeLimit(.minutes(1)))
struct ListenQueueTests {
  @Test("More harness requests at once than a listen queue holds all get their answer")
  func moreRequestsThanTheQueueHolds() async throws {
    let server = try LateAcceptingServer(queue: 128, acceptAfter: .seconds(1))
    let count = 200
    let statuses = try await withThrowingTaskGroup { tasks in
      for number in 1...count {
        tasks.addTask { try await TestHTTP.send("POST", server.url, json: ["n": .number(Double(number))]).status }
      }
      var statuses: [Int] = []
      for try await status in tasks { statuses.append(status) }
      return statuses
    }
    #expect(statuses == Array(repeating: 200, count: count))
    #expect(server.answered == count)
  }
}

/// A server whose listen queue holds `queue` connections, and which accepts none until `acceptAfter` has passed: a
/// server on a busy machine, all at once.
private final class LateAcceptingServer: Sendable {
  let url: URL
  var answered: Int { count.value.withLock { $0 } }

  private let socket: Int32
  private let count = Count()

  private final class Count: Sendable {
    let value = Mutex(0)
  }

  init(queue: Int32, acceptAfter delay: Duration) throws {
    let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard socket >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
        bind(socket, address, length) == 0 && listen(socket, queue) == 0
          && getsockname(socket, address, &length) == 0
      }
    }
    guard bound, let url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/a") else {
      close(socket)
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    self.socket = socket
    self.url = url
    let count = count
    let thread = Thread {
      Thread.sleep(forTimeInterval: Double(delay.components.seconds))
      while true {
        let connection = accept(socket, nil, nil)
        guard connection >= 0 else { return }
        DispatchQueue.global().async {
          if Self.answer(connection) { count.value.withLock { $0 += 1 } }
          close(connection)
        }
      }
    }
    thread.start()
  }

  deinit {
    // The accepting thread's `accept` fails once the socket is shut down, and the thread ends.
    shutdown(socket, SHUT_RDWR)
    close(socket)
  }

  /// Reads one request, with its body, and answers it.
  private static func answer(_ connection: Int32) -> Bool {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 1 << 16)
    while true {
      if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).lowercased()
        let length =
          head.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
          .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        if buffer.count - end.upperBound >= length { break }
      }
      let read = chunk.withUnsafeMutableBytes { recv(connection, $0.baseAddress, $0.count, 0) }
      guard read > 0 else { return false }
      buffer.append(contentsOf: chunk[..<read])
    }
    let answer = Data(
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".utf8)
    let sent = answer.withUnsafeBytes { send(connection, $0.baseAddress, $0.count, 0) }
    return sent == answer.count
  }
}
