import Darwin
import Foundation
import Synchronization

/// A real Wishbone server for tests: the pinned release, built by `just server`.
///
/// See "A real server" and "Servers in parallel" in `docs/development.md`.
///
/// - `shared()` is the one server that the tests of a test process share. Each test seeds its own family on it.
/// - `start()` is a private server, for a test that needs its own instance: an empty one, sign-in from setup, or
///   its own settings.
/// - Every server gets a free port and a fresh data folder in a `ScratchDirectory`. It stops when its last holder
///   goes, and when the test process exits.
public final class TestServer: Sendable {
  /// The path that every API route is under.
  public static let apiPrefix = "/api/v2"

  /// The instance address, such as `http://localhost:50123`. It is the server's public address, so the login links
  /// that the server makes start with it.
  public let address: URL
  public let port: Int

  /// The server's data folder.
  public let dataFolder: URL

  /// The setup code that the server wrote to its log when it started with no users.
  public let setupCode: String

  private let folder: ScratchDirectory
  private let process: Subprocess
  private let logFile: URL
  private let adminSession = Mutex<Task<BearerSession, any Error>?>(nil)

  private init(port: Int, setupCode: String, folder: ScratchDirectory, process: Subprocess) throws {
    guard let address = URL(string: "http://localhost:\(port)") else { throw URLError(.badURL) }
    self.address = address
    self.port = port
    self.setupCode = setupCode
    self.folder = folder
    self.process = process
    dataFolder = Self.dataFolder(in: folder)
    logFile = Self.logFile(in: folder)
  }

  deinit {
    stop()
  }

  /// What the server has written to its log.
  public var log: String {
    Self.log(at: logFile)
  }

  public var isRunning: Bool {
    process.isRunning
  }

  /// Stops the server, and removes its data folder. The last holder's release does this too.
  public func stop() {
    process.stop()
    folder.remove()
  }

  /// A URL on the server for a path under `/api/v2`, such as `/health`. The path has no query.
  public func url(_ path: String) -> URL {
    address.appending(path: Self.apiPrefix + path)
  }

  // MARK: - Starting

  /// The server that the tests of this test process share. The first call starts it.
  public static func shared() async throws -> TestServer {
    let task = sharedServer.withLock { shared in
      if let shared { return shared }
      let task = Task { try await start() }
      shared = task
      return task
    }
    return try await task.value
  }

  private static let sharedServer = Mutex<Task<TestServer, any Error>?>(nil)

  /// Starts a private server, with an empty data folder.
  ///
  /// `environment` adds to the server's environment, or replaces a setting below. `build` is the built server to
  /// run: a checkout that has none fails the call.
  public static func start(
    environment: [String: String] = [:],
    from build: ServerBuild = .current
  ) async throws -> TestServer {
    let binary = try build.binary()
    // `freePort` frees its port before the server binds it, so another process can take the port in between.
    // The server then ends at once, and the next try picks another port.
    for _ in 0..<5 {
      let folder = try ScratchDirectory("server")
      let port = try freePort()
      let settings = [
        // The zone of a user who has no timezone.
        "TZ": "UTC",
        "WISHBONE_PORT": "\(port)",
        // A name, not an IP address: the server refuses an IP address here, for passkeys.
        "WISHBONE_PUBLIC_URL": "http://localhost:\(port)",
        "WISHBONE_DATA_DIR": dataFolder(in: folder).path(percentEncoded: false),
        // Every test redeems login links from one address, so the limit must be out of reach.
        "WISHBONE_RATE_LIMIT_REDEEM": "1000000",
        // The reveal hook, and link reads from a fixture page on this machine. Only the e2e build has them.
        "WISHBONE_E2E_HOOKS": "true",
        "WISHBONE_EXTRACT_ALLOW_PRIVATE": "true",
      ].merging(environment) { _, added in added }
      // The server reads a `.env` file from its folder. The scratch folder has none.
      let process = try Subprocess(
        binary,
        arguments: ["serve"],
        environment: settings,
        directory: folder.url,
        output: logFile(in: folder)
      )
      try folder.adopt(process.identity)
      if let setupCode = try await setupCode(of: process, port: port, logFile: logFile(in: folder)) {
        return try TestServer(port: port, setupCode: setupCode, folder: folder, process: process)
      }
    }
    throw DidNotStart(reason: "another process took its port, five times", log: "")
  }

  public struct DidNotStart: Error, CustomStringConvertible {
    public let reason: String
    public let log: String

    public var description: String {
      "The test server did not start: \(reason).\(log.isEmpty ? "" : " Its log:\n\(log)")"
    }
  }

  private static func dataFolder(in folder: ScratchDirectory) -> URL {
    folder.url.appending(path: "data", directoryHint: .isDirectory)
  }

  private static func logFile(in folder: ScratchDirectory) -> URL {
    folder.url.appending(path: "server.log")
  }

  private static func log(at file: URL) -> String {
    (try? String(contentsOf: file, encoding: .utf8)) ?? ""
  }

  /// Waits until the server answers its health check, and returns the setup code from its log. Nil when the
  /// server ended because its port was taken.
  private static func setupCode(of process: Subprocess, port: Int, logFile: URL) async throws -> String? {
    guard let health = URL(string: "http://127.0.0.1:\(port)\(apiPrefix)/health") else { throw URLError(.badURL) }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(30))
    while clock.now < deadline {
      guard process.isRunning else {
        let log = log(at: logFile)
        if log.contains("address already in use") { return nil }
        throw DidNotStart(reason: "it ended before it listened", log: log)
      }
      // The server writes the code before it listens.
      if let code = log(at: logFile).firstMatch(of: /setup_code="?([A-Z0-9-]+)/)?.1,
        let answer = try? await TestHTTP.send("GET", health), answer.status == 200
      {
        // Another process on the port would answer too. A server that could not bind the port ends within a
        // moment, so see that this one stays.
        try await Task.sleep(for: .milliseconds(100))
        if process.isRunning { return String(code) }
      } else {
        try await Task.sleep(for: .milliseconds(20))
      }
    }
    throw DidNotStart(reason: "it did not answer its health check in 30 seconds", log: log(at: logFile))
  }

  /// A port that nothing listens on, right now. The server listens on every address, so the probe does too.
  private static func freePort() throws -> Int {
    let probe = socket(AF_INET6, SOCK_STREAM, 0)
    guard probe >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    defer { close(probe) }
    var address = sockaddr_in6()
    address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    address.sin6_family = sa_family_t(AF_INET6)
    address.sin6_addr = in6addr_any
    var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
    let bound = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
        bind(probe, pointer, length) == 0 && getsockname(probe, pointer, &length) == 0
      }
    }
    guard bound else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    return Int(UInt16(bigEndian: address.sin6_port))
  }

  // MARK: - The admin

  /// The admin's bearer session. The first call sets the instance up, with the setup code, and makes the admin.
  ///
  /// A test that needs an instance with no users starts a private server, and doesn't call this.
  public func admin() async throws -> BearerSession {
    let task = adminSession.withLock { session in
      if let session { return session }
      let task = Task { try await setUp() }
      session = task
      return task
    }
    return try await task.value
  }

  /// Sets the instance up, as the web app's setup screen does, and signs the admin in as a native app does.
  private func setUp() async throws -> BearerSession {
    // Setup starts a cookie session only. The cookie makes the admin's login link, and a login link gives a
    // bearer session.
    let admin: JSON = [
      "setup_code": .string(setupCode), "name": "Ada", "last_name": "Admin", "birthday": ["month": 2, "day": 29],
    ]
    let made = try await TestHTTP.send("POST", url("/setup"), json: admin).expecting(201)
    guard let cookie = made.headers["set-cookie"]?.split(separator: ";").first else {
      throw DidNotStart(reason: "setup gave no session cookie", log: log)
    }
    let asAdmin = ["Cookie": String(cookie)]
    try await TestHTTP.send("POST", url("/users/me/confirm-profile"), headers: asAdmin).expecting(200)
    let link = try await TestHTTP.send("POST", url("/users/me/login-links"), headers: asAdmin).expecting(201).json
    guard let link = link["url"].string.flatMap(URL.init(string:)) else {
      throw DidNotStart(reason: "the admin's login link has no address", log: log)
    }
    return try await redeem(link)
  }

  /// Redeems a login link for a bearer session, as the app does. The link is used up.
  public func redeem(_ loginLink: URL) async throws -> BearerSession {
    let body: JSON = ["token": .string(loginLink.lastPathComponent), "session": "bearer"]
    let answer = try await TestHTTP.send("POST", url("/login-links/redeem"), json: body).expecting(200).json
    guard let token = answer["token"].string, let userID = answer["user_id"].string else {
      throw URLError(.cannotParseResponse)
    }
    return BearerSession(instance: address, token: token, userID: userID)
  }
}
