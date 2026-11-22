import Foundation
import Testing
import WishboneUI

/// The app's own markdown renderer: the web's subset renders, a web link is marked as one that opens in the
/// browser, and anything else shows as typed. See "Dependencies" in `docs/architecture.md`.
@Suite("The markdown renderer", .timeLimit(.minutes(1)))
@MainActor
struct MarkdownTests {
  /// A line's runs as a test names them: the words, and the marks on them.
  struct Run: Equatable, CustomStringConvertible {
    let words: String
    var strong = false
    var emphasized = false
    var code = false
    var link: String?

    var description: String {
      let marks = [strong ? "strong" : nil, emphasized ? "em" : nil, code ? "code" : nil, link.map { "link \($0)" }]
      return "\(words.debugDescription) \(marks.compactMap { $0 })"
    }
  }

  private func runs(_ line: AttributedString) -> [Run] {
    line.runs.map { run in
      let intent = run.inlinePresentationIntent ?? []
      return Run(
        words: String(line[run.range].characters), strong: intent.contains(.stronglyEmphasized),
        emphasized: intent.contains(.emphasized), code: intent.contains(.code), link: run.link?.absoluteString)
    }
  }

  /// The text of each line of each block, with the block's kind.
  private func shape(_ text: String) -> [String] {
    Markdown.blocks(text).map { block in
      switch block {
      case .paragraph(let lines): "p: \(lines.map { String($0.characters) })"
      case .heading(let text): "h: \(String(text.characters))"
      case .bullets(let items): "ul: \(items.map { String($0.characters) })"
      case .numbers(let items): "ol: \(items.map { String($0.characters) })"
      }
    }
  }

  private func line(_ text: String) throws -> AttributedString {
    guard case .paragraph(let lines) = try #require(Markdown.blocks(text).first) else {
      Issue.record("Not a paragraph: \(text)")
      return AttributedString()
    }
    return try #require(lines.first)
  }

  @Test("The web's subset renders: paragraphs, line breaks, lists, headings, bold, italic, and code")
  func subset() throws {
    #expect(shape("one\ntwo\n\nthree") == [#"p: ["one", "two"]"#, #"p: ["three"]"#])
    #expect(shape("- a\n* b\n\n1. x\n2) y") == [#"ul: ["a", "b"]"#, #"ol: ["x", "y"]"#])
    #expect(shape("## Sizes\nMedium") == ["h: Sizes", #"p: ["Medium"]"#])
    #expect(shape("").isEmpty)
    #expect(shape("  \n\n ").isEmpty)

    #expect(
      runs(try line("**bold** *it* _it2_ `c`")) == [
        Run(words: "bold", strong: true), Run(words: " "), Run(words: "it", emphasized: true), Run(words: " "),
        Run(words: "it2", emphasized: true), Run(words: " "), Run(words: "c", code: true),
      ])
    #expect(
      runs(try line("Size **medium _please_**")) == [
        Run(words: "Size "), Run(words: "medium ", strong: true), Run(words: "please", strong: true, emphasized: true),
      ])
  }

  @Test("A web link is a link, read as one that opens in the browser")
  func webLink() throws {
    let text = try line("See [the shop](https://shop.example/a?b=1) for sizes.")
    #expect(
      runs(text) == [
        Run(words: "See "), Run(words: "the shop", link: "https://shop.example/a?b=1"), Run(words: " for sizes."),
      ])
    #expect(Markdown.spoken(text) == "See the shop, opens in browser for sizes.")
    #expect(runs(try line("[Plain](http://shop.example)")).first?.link == "http://shop.example")
    // A line with no link reads as it shows.
    #expect(Markdown.spoken(try line("Likes tea")) == "Likes tea")
  }

  @Test("Anything else shows as typed: raw HTML, a link to another scheme, and stray marks")
  func anythingElse() throws {
    let html = "<script>alert(1)</script> <b>bold</b>"
    #expect(runs(try line(html)) == [Run(words: html)])
    for address in ["javascript:alert(1)", "JaVaScRiPt:alert(1)", "data:text/html,hi", "mailto:a@b.example"] {
      let typed = "[click](\(address))"
      #expect(runs(try line(typed)) == [Run(words: typed)], "\(address)")
    }
    #expect(runs(try line("2 * 3 * 4 and snake_case_name")) == [Run(words: "2 * 3 * 4 and snake_case_name")])
    #expect(runs(try line("> a quote | a table")) == [Run(words: "> a quote | a table")])
  }
}
