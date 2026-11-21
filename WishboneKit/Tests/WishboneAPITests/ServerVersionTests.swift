import Testing
import WishboneAPI

@Suite("A server version that the app can compare", .timeLimit(.minutes(1)))
struct ServerVersionTests {
  @Test(
    "An older version comes before a newer one",
    arguments: [
      ("2.1.9", "2.2.0"),
      ("2.2.0", "2.2.1"),
      ("2.9.0", "2.10.0"),
      ("1.99.99", "2.0.0"),
      ("v2.1.0+7773ada", "2.2.0"),
      // A pre-release comes before its release.
      ("2.2.0-rc.1", "2.2.0"),
    ]
  )
  func order(older: String, newer: String) throws {
    let older = try #require(ServerVersion(older))
    let newer = try #require(ServerVersion(newer))
    #expect(older < newer)
    #expect(!(newer < older))
    #expect(older != newer)
  }

  @Test("What a build adds to a version doesn't count")
  func buildDoesNotCount() throws {
    let stamped = try #require(ServerVersion("v2.2.0+7773ada"))
    #expect(stamped == ServerVersion("2.2.0"))
    #expect(stamped.text == "2.2.0")
  }

  @Test(
    "The app can't read a version that is not three numbers",
    arguments: ["dev", "", "2.2", "2.2.0.1", "two.2.0", "2.-1.0"])
  func unreadable(text: String) {
    #expect(ServerVersion(text) == nil)
  }

  @Test("The minimum server version reads")
  func minimumReads() {
    #expect(ServerVersion(minimumServerVersion) != nil)
  }
}
