import Foundation
import SwiftUI

/// The app's own small renderer for the web's markdown subset: good to know, and a list's description. See
/// "Dependencies" in `docs/architecture.md`, and "Web links" in `docs/spec.md`.
///
/// It renders what the web app renders, and nothing more: paragraphs, line breaks, bullet and numbered lists,
/// headings (as small headings), bold, italic, inline code, and links to `http` and `https` addresses. Anything else
/// shows as typed, raw HTML included, and a link to another scheme shows as the text that was typed.
///
/// A web link opens in the default browser, never in the app: the system opens an `https` address there. VoiceOver
/// reads each link's words, then "opens in browser".
public enum Markdown {
  /// A block of the text.
  public enum Block: Equatable, Sendable {
    /// A paragraph. Each line of the paragraph is a line of its own.
    case paragraph([AttributedString])

    /// A heading, of any level, shown as a small heading.
    case heading(AttributedString)
    case bullets([AttributedString])
    case numbers([AttributedString])
  }

  /// The text's blocks, in order. Blank text has none.
  public static func blocks(_ text: String) -> [Block] {
    var blocks: [Building] = []
    let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    for line in lines.map(String.init) {
      if line.allSatisfy(\.isWhitespace) {
        // A blank line ends the block.
        blocks.append(.paragraph([]))
      } else if let text = match(heading, line) {
        blocks.append(.heading(text))
        blocks.append(.paragraph([]))
      } else if let text = match(bullet, line) {
        if case .bullets(let items) = blocks.last {
          blocks[blocks.count - 1] = .bullets(items + [text])
        } else {
          blocks.append(.bullets([text]))
        }
      } else if let text = match(numbered, line) {
        if case .numbers(let items) = blocks.last {
          blocks[blocks.count - 1] = .numbers(items + [text])
        } else {
          blocks.append(.numbers([text]))
        }
      } else {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if case .paragraph(let lines) = blocks.last {
          blocks[blocks.count - 1] = .paragraph(lines + [trimmed])
        } else {
          blocks.append(.paragraph([trimmed]))
        }
      }
    }
    return blocks.compactMap { block in
      switch block {
      case .paragraph(let lines): lines.isEmpty ? nil : .paragraph(lines.map { inline($0) })
      case .heading(let text): .heading(inline(text))
      case .bullets(let items): .bullets(items.map { inline($0) })
      case .numbers(let items): .numbers(items.map { inline($0) })
      }
    }
  }

  /// What VoiceOver reads for a line: its words, with "opens in browser" after the words of each web link.
  public static func spoken(_ line: AttributedString) -> String {
    var spoken = AttributedString()
    for run in line.runs {
      let words = AttributedString(line[run.range].characters)
      if run.link != nil {
        spoken.append(
          AttributedString(String(localized: "\(String(words.characters)), opens in browser", bundle: #bundle)))
      } else {
        spoken.append(words)
      }
    }
    return String(spoken.characters)
  }

  // MARK: - Blocks

  /// A block while the lines come in, before its text is rendered.
  private enum Building {
    case paragraph([String])
    case heading(String)
    case bullets([String])
    case numbers([String])
  }

  private static let bullet = expression(Pattern.bullet)
  private static let numbered = expression(Pattern.numbered)
  private static let heading = expression(Pattern.heading)

  /// The first group of the expression's match of the whole line. Nil when it doesn't match.
  private static func match(_ expression: NSRegularExpression, _ line: String) -> String? {
    let whole = NSRange(line.startIndex..., in: line)
    guard let found = expression.firstMatch(in: line, range: whole),
      let group = Range(found.range(at: 1), in: line)
    else { return nil }
    return String(line[group])
  }

  // MARK: - Inline

  /// The inline marks, in the order in which they win when two start at the same place.
  private enum Mark: CaseIterable {
    case code, strong, strongUnderscores, emphasis, emphasisUnderscores, link

    var expression: NSRegularExpression {
      switch self {
      case .code: Markdown.code
      case .strong: Markdown.strong
      case .strongUnderscores: Markdown.strongUnderscores
      case .emphasis: Markdown.emphasis
      case .emphasisUnderscores: Markdown.emphasisUnderscores
      case .link: Markdown.link
      }
    }
  }

  private static let code = expression(Pattern.code)
  private static let strong = expression(Pattern.strong)
  private static let strongUnderscores = expression(Pattern.strongUnderscores)
  private static let emphasis = expression(Pattern.emphasis)
  private static let emphasisUnderscores = expression(Pattern.emphasisUnderscores)
  private static let link = expression(Pattern.link)

  /// One line of a paragraph, a list item, or a heading, with its marks rendered.
  private static func inline(_ text: String, intent: InlinePresentationIntent = []) -> AttributedString {
    var out = AttributedString()
    var rest = Substring(text)
    while !rest.isEmpty {
      let string = String(rest)
      let whole = NSRange(string.startIndex..., in: string)
      var best: (mark: Mark, match: NSTextCheckingResult)?
      for mark in Mark.allCases {
        guard let found = mark.expression.firstMatch(in: string, range: whole) else { continue }
        if best == nil || found.range.location < best!.match.range.location { best = (mark, found) }
      }
      guard let best, let range = Range(best.match.range, in: string) else { break }
      out.append(plain(String(string[..<range.lowerBound]), intent: intent))
      out.append(render(best.mark, best.match, in: string, intent: intent))
      rest = Substring(string[range.upperBound...])
    }
    out.append(plain(String(rest), intent: intent))
    return out
  }

  private static func render(
    _ mark: Mark, _ found: NSTextCheckingResult, in string: String, intent: InlinePresentationIntent
  ) -> AttributedString {
    let group = { (index: Int) in Range(found.range(at: index), in: string).map { String(string[$0]) } ?? "" }
    switch mark {
    case .code:
      return plain(group(1), intent: intent.union(.code))
    case .strong, .strongUnderscores:
      return inline(group(1), intent: intent.union(.stronglyEmphasized))
    case .emphasis, .emphasisUnderscores:
      return inline(group(1), intent: intent.union(.emphasized))
    case .link:
      let address = group(2)
      guard let url = URL(string: address), let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https"
      else {
        // Not a web link: what was typed shows, with no link.
        return plain(Range(found.range, in: string).map { String(string[$0]) } ?? "", intent: intent)
      }
      var words = inline(group(1), intent: intent)
      words.link = url
      return words
    }
  }

  private static func plain(_ text: String, intent: InlinePresentationIntent) -> AttributedString {
    var out = AttributedString(text)
    if !intent.isEmpty { out.inlinePresentationIntent = intent }
    return out
  }

  /// The patterns of the blocks and of the inline marks, as the web app has them.
  private enum Pattern {
    static let bullet = #"^\s*[-*+]\s+(.*)$"#
    static let numbered = #"^\s*\d+[.)]\s+(.*)$"#
    static let heading = #"^\s*#{1,6}\s+(.*)$"#
    static let code = #"`([^`]+)`"#
    static let strong = #"\*\*(.+?)\*\*"#
    static let strongUnderscores = #"(?<!\w)__(.+?)__(?!\w)"#
    static let emphasis = #"\*(?=\S)(.+?)(?<=\S)\*"#
    static let emphasisUnderscores = #"(?<!\w)_(?=\S)(.+?)(?<=\S)_(?!\w)"#
    static let link = #"\[([^\]]+)\]\(([^)\s]+)\)"#
  }

  /// The patterns are fixed, and each one compiles.
  private static func expression(_ pattern: String) -> NSRegularExpression {
    // A fixed pattern that doesn't compile is a fault of this file, which the hosted tests find at once.
    try! NSRegularExpression(pattern: pattern)
  }
}

/// Markdown, as the web's subset renders it, in the body's text style. Each block is one element for VoiceOver,
/// which reads each web link's words, then "opens in browser".
struct MarkdownView: View {
  let blocks: [Markdown.Block]

  init(_ text: String) {
    blocks = Markdown.blocks(text)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        switch block {
        case .paragraph(let lines):
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
              MarkdownLine(text: line)
            }
          }
        case .heading(let text):
          MarkdownLine(text: text)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
        case .bullets(let items):
          list(items) { _ in
            Image(systemName: "circle.fill")
              .font(.system(.caption2))
              .imageScale(.small)
          }
        case .numbers(let items):
          list(items) { index in Text(index + 1, format: .number) }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// A list's items, each with its marker.
  private func list<Marker: View>(
    _ items: [AttributedString], @ViewBuilder marker: @escaping (Int) -> Marker
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(items.enumerated()), id: \.offset) { index, item in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          marker(index)
            .accessibilityHidden(true)
          MarkdownLine(text: item)
        }
      }
    }
  }
}

/// One line of markdown. A line with a web link reads its words, then "opens in browser", after each link.
private struct MarkdownLine: View {
  let text: AttributedString

  var body: some View {
    let hasLink = text.runs.contains { $0.link != nil }
    Text(text)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityLabel(hasLink ? Text(Markdown.spoken(text)) : Text(text))
  }
}
