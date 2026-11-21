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
}
