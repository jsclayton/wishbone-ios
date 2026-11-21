import Foundation

/// One Swift file, ready to scan.
struct SourceFile {
  /// The file's path from the repo's root.
  let path: String

  /// The file's text, with every comment and the inside of every string literal blanked. See `SwiftCode`.
  let code: String

  init(path: String, source: String) {
    self.path = path
    self.code = SwiftCode.blankingCommentsAndStrings(in: source)
  }

  /// Each place where the pattern matches the code.
  func findings(of pattern: String, as what: String) -> [Finding] {
    matches(of: pattern).map { finding(at: $0.lowerBound, what) }
  }

  func matches(of pattern: String) -> [Range<String.Index>] {
    code.matches(of: Self.regex(pattern)).map(\.range)
  }

  /// A pattern for scanning code. `^` and `$` match at each line. `\b` is the simple word boundary: the default
  /// one follows Unicode's rules for prose, which put no boundary at the period in `content.badge`.
  static func regex(_ pattern: String) -> Regex<AnyRegexOutput> {
    // The patterns are literals in the tests, so one that doesn't compile is a fault in a test.
    // swift-format-ignore: NeverUseForceTry
    try! Regex(pattern).anchorsMatchLineEndings().wordBoundaryKind(.simple)
  }

  func finding(at index: String.Index, _ what: String) -> Finding {
    let line = code[..<index].count { $0.isNewline } + 1
    return Finding(path: path, line: line, what: what)
  }

  /// The opening parenthesis of the call that the index is inside, if it is inside one.
  func openingParenthesis(around index: String.Index) -> String.Index? {
    var depth = 0
    var index = index
    while index > code.startIndex {
      index = code.index(before: index)
      switch code[index] {
      case ")":
        depth += 1
      case "(":
        if depth == 0 {
          return index
        }
        depth -= 1
      default:
        break
      }
    }
    return nil
  }

  /// The text between an opening parenthesis and the one that closes it.
  func arguments(openedAt open: String.Index) -> Substring {
    var depth = 0
    var index = open
    while index < code.endIndex {
      switch code[index] {
      case "(":
        depth += 1
      case ")":
        depth -= 1
        if depth == 0 {
          return code[code.index(after: open)..<index]
        }
      default:
        break
      }
      index = code.index(after: index)
    }
    return code[code.index(after: open)...]
  }
}

/// One place where the code breaks a rule.
struct Finding: Equatable, CustomStringConvertible {
  let path: String
  let line: Int
  let what: String

  var description: String {
    "\(path):\(line): \(what)"
  }
}

extension [Finding] {
  /// The findings as lines, for a test's failure message.
  var report: String {
    map(\.description).joined(separator: "\n")
  }
}
