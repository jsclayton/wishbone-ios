import Testing
import WishboneAPI

@Suite("A login link, and the instance address in it", .timeLimit(.minutes(1)))
struct LoginLinkTests {
  @Test(
    "The instance address is all the text before /login/",
    arguments: [
      ("https://wishbone.example/login/abc123", "https://wishbone.example"),
      ("http://10.0.0.5:8080/login/abc123", "http://10.0.0.5:8080"),
      ("http://localhost:8080/login/abc_123-XYZ", "http://localhost:8080"),
      ("https://example.com/family/wishes/login/abc123", "https://example.com/family/wishes"),
      // An instance address can have /login/ in its own path. The token is after the last one.
      ("https://example.com/login/login/abc123", "https://example.com/login"),
      ("  https://wishbone.example/login/abc123\n", "https://wishbone.example"),
      ("HTTPS://Wishbone.Example/login/abc123", "HTTPS://Wishbone.Example"),
    ]
  )
  func instanceAddress(text: String, address: String) throws {
    let link = try #require(LoginLink(text))
    #expect(link.instance.text == address)
    #expect(link.instance == InstanceAddress(address))
  }

  @Test(
    "Anything else is not a login link",
    arguments: [
      "",
      "Kite",
      "https://wishbone.example",
      "https://wishbone.example/lists/7",
      "https://wishbone.example/login/",
      "https://wishbone.example/login/abc123/more",
      "https://wishbone.example/login/abc123?next=home",
      "https://wishbone.example/login/abc 123",
      "wishbone.example/login/abc123",
      "ftp://wishbone.example/login/abc123",
      "https:///login/abc123",
      "/login/abc123",
    ]
  )
  func notALoginLink(text: String) {
    #expect(LoginLink(text) == nil)
  }

  @Test("A login link and a session never print their secret")
  func secretsStayOut() throws {
    let link = try #require(LoginLink("https://wishbone.example/login/s3cr3t-link-token"))
    #expect(!"\(link)".contains("s3cr3t"))
    #expect(!String(reflecting: link).contains("s3cr3t"))

    let session = Session(instance: link.instance, token: "s3cr3t-session-token", userID: "7")
    #expect(!"\(session)".contains("s3cr3t"))
    #expect(!String(reflecting: session).contains("s3cr3t"))
  }
}
