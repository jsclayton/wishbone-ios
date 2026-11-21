import Testing

@Suite("The scans see only code", .timeLimit(.minutes(1)))
struct SwiftCodeTests {
  @Test("A comment is blanked, and a line keeps its number")
  func comments() {
    let code = SwiftCode.blankingCommentsAndStrings(
      in: """
        let a = 1 // import Sentry
        /* import Sentry
           /* nested */ still a comment */
        let b = 2
        """
    )
    #expect(!code.contains("Sentry"))
    #expect(!code.contains("comment"))
    #expect(code.split(separator: "\n", omittingEmptySubsequences: false).count == 4)
    #expect(code.contains("let a = 1"))
    #expect(code.contains("let b = 2"))
  }

  @Test("The inside of a string is blanked, and its quotes stay")
  func strings() {
    let inside = "https://example.com/a(b"
    let code = SwiftCode.blankingCommentsAndStrings(in: #"let url = "\#(inside)" + name"#)
    #expect(code == #"let url = "\#(String(repeating: " ", count: inside.count))" + name"#)
  }

  @Test("An escaped quote doesn't end a string")
  func escapedQuote() {
    let code = SwiftCode.blankingCommentsAndStrings(in: #"let a = "say \"import Sentry\" now"; let b = 1"#)
    #expect(!code.contains("Sentry"))
    #expect(code.hasSuffix("; let b = 1"))
  }

  @Test("The code inside an interpolation stays")
  func interpolation() {
    let code = SwiftCode.blankingCommentsAndStrings(in: #"Text("Hello \(name.joined(separator: ", ")) there")"#)
    #expect(code.contains("name.joined(separator:"))
    #expect(!code.contains("Hello"))
    #expect(!code.contains("there"))
    #expect(code.hasSuffix(#"")"#))
  }

  @Test("A multi-line string and a raw string are blanked")
  func otherStrings() {
    let code = SwiftCode.blankingCommentsAndStrings(
      in: ##"""
        let a = """
          import Sentry "quoted"
          """
        let b = #"import "Sentry" \(not code)"#
        let c = #bundle
        """##
    )
    #expect(!code.contains("Sentry"))
    #expect(!code.contains("quoted"))
    #expect(!code.contains("not code"))
    #expect(code.contains("let c = #bundle"))
  }
}
