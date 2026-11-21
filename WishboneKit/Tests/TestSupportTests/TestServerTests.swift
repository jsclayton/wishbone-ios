import Darwin
import Foundation
import TestSupport
import Testing

@Suite("The server harness", .timeLimit(.minutes(1)))
struct TestServerTests {
  @Test("Two test servers get different ports and data folders")
  func twoServers() async throws {
    async let first = TestServer.start()
    async let second = TestServer.start()
    let servers = try await [first, second]

    #expect(servers[0].port != servers[1].port)
    #expect(servers[0].dataFolder != servers[1].dataFolder)
    for server in servers {
      #expect(try await TestHTTP.send("GET", server.url("/health")).status == 200)
      // Each has its own database, in its own data folder.
      #expect(FileManager.default.fileExists(atPath: server.dataFolder.appending(path: "wishbone.db").path()))
      #expect(try await TestHTTP.send("GET", server.url("/setup")).json["is_needed"] == true)
    }
  }

  @Test("A server stops, and its data folder goes, when its holder goes")
  func stopsWithItsHolder() async throws {
    var server: TestServer? = try await TestServer.start()
    let health = try #require(server?.url("/health"))
    let dataFolder = try #require(server?.dataFolder)
    #expect(try await TestHTTP.send("GET", health).status == 200)

    server = nil

    await #expect(throws: URLError.self) { try await TestHTTP.send("GET", health) }
    #expect(!FileManager.default.fileExists(atPath: dataFolder.path()))
  }

  @Test("A missing server fails the test, and never skips it")
  func missingServerFails() async throws {
    // A checkout that has the pin, and no built server.
    let checkout = try ScratchDirectory("checkout")
    let build = ServerBuild(checkout: checkout.url)
    try FileManager.default.createDirectory(
      at: build.pinFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: ServerBuild.current.pinFile, to: build.pinFile)

    // The harness throws, so the test that asked for a server fails. A skip would need `Test.cancel` or a
    // condition trait, and the gate fails on a skip that is not on its list.
    let error = await #expect(throws: ServerBuild.NotBuilt.self) { try await TestServer.start(from: build) }
    #expect(error?.description.contains("just server") == true)
  }

  @Test("A test server listens on 127.0.0.1 only, so the local network can't reach it")
  func loopbackOnly() async throws {
    let server = try await TestServer.start()
    let loopback = try #require(SocketAddress.ipv4("127.0.0.1", port: server.port))
    #expect(SocketAddress.accepting([loopback]).count == 1, "the server does not answer at 127.0.0.1")

    // Every address of this machine's other interfaces, as the local network sees it.
    let others = SocketAddress.nonLoopback(port: server.port)
    try #require(!others.isEmpty, "this machine has no address beside loopback, so the test can't dial one")
    for address in SocketAddress.accepting(others) {
      Issue.record("the server answers at \(address)")
    }
  }
}

/// A TCP address to dial, for the loopback test.
private struct SocketAddress: CustomStringConvertible {
  var storage = sockaddr_storage()
  var description: String

  static func ipv4(_ text: String, port: Int) -> SocketAddress? {
    var address = sockaddr_in()
    guard inet_pton(AF_INET, text, &address.sin_addr) == 1 else { return nil }
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    var result = SocketAddress(description: "\(text):\(port)")
    withUnsafeBytes(of: &address) { bytes in
      withUnsafeMutableBytes(of: &result.storage) { $0.copyMemory(from: bytes) }
    }
    return result
  }

  /// The IPv4 and IPv6 addresses, but for link-local ones, of every interface that is up and is not loopback, at
  /// `port`.
  static func nonLoopback(port: Int) -> [SocketAddress] {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return [] }
    defer { freeifaddrs(list) }
    var addresses: [SocketAddress] = []
    var next = list
    while let entry = next?.pointee {
      defer { next = entry.ifa_next }
      let flags = Int32(entry.ifa_flags)
      guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let found = entry.ifa_addr else { continue }
      let family = Int32(found.pointee.sa_family)
      guard family == AF_INET || family == AF_INET6 else { continue }
      // A link-local IPv6 address is on one link only, such as a tunnel's, and a dial to one can hang until it
      // times out.
      let isLinkLocal = found.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { address in
        family == AF_INET6 && address.pointee.sin6_addr.__u6_addr.__u6_addr8.0 == 0xfe
          && address.pointee.sin6_addr.__u6_addr.__u6_addr8.1 & 0xc0 == 0x80
      }
      guard !isLinkLocal else { continue }
      var result = SocketAddress(description: "")
      withUnsafeMutableBytes(of: &result.storage) { storage in
        storage.copyMemory(from: UnsafeRawBufferPointer(start: found, count: Int(found.pointee.sa_len)))
      }
      withUnsafeMutableBytes(of: &result.storage) { storage in
        // The port is at the same place in both families.
        storage.storeBytes(of: in_port_t(UInt16(port).bigEndian), toByteOffset: 2, as: in_port_t.self)
      }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      _ = withUnsafePointer(to: &result.storage) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
          getnameinfo(pointer, socklen_t(pointer.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        }
      }
      let text = String(decoding: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
      result.description = "\(text) port \(port), on \(String(cString: entry.ifa_name))"
      addresses.append(result)
    }
    return addresses
  }

  /// The addresses where a TCP connection opens within two seconds. It dials them all at once, so an address that
  /// never answers costs the two seconds once.
  static func accepting(_ addresses: [SocketAddress]) -> [SocketAddress] {
    var dials: [(address: SocketAddress, socket: Int32)] = []
    defer { for dial in dials { close(dial.socket) } }
    var accepted: [SocketAddress] = []
    for address in addresses {
      var storage = address.storage
      let length = socklen_t(storage.ss_len)
      let probe = socket(Int32(storage.ss_family), SOCK_STREAM, 0)
      guard probe >= 0 else { continue }
      dials.append((address, probe))
      _ = fcntl(probe, F_SETFL, fcntl(probe, F_GETFL) | O_NONBLOCK)
      let started = withUnsafePointer(to: &storage) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, length) }
      }
      if started == 0 { accepted.append(address) }
    }
    var pending = dials.filter { dial in !accepted.contains { $0.description == dial.address.description } }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !pending.isEmpty, ContinuousClock.now < deadline {
      var pollers = pending.map { pollfd(fd: $0.socket, events: Int16(POLLOUT), revents: 0) }
      let left = Int32((deadline - ContinuousClock.now) / .milliseconds(1)) + 1
      guard poll(&pollers, nfds_t(pollers.count), left) > 0 else { break }
      var waiting: [(address: SocketAddress, socket: Int32)] = []
      for (dial, poller) in zip(pending, pollers) {
        guard poller.revents != 0 else {
          waiting.append(dial)
          continue
        }
        var failure: Int32 = 0
        var failureLength = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(dial.socket, SOL_SOCKET, SO_ERROR, &failure, &failureLength)
        if failure == 0 { accepted.append(dial.address) }
      }
      pending = waiting
    }
    return accepted
  }
}
