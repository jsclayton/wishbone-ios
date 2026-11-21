/// A small reader of Swift source, so that a scan sees only code.
enum SwiftCode {
  /// The source with every comment and the inside of every string literal replaced by spaces.
  ///
  /// Line breaks, the quotes of a literal, and the code inside an interpolation stay. So a pattern never matches
  /// words in a comment or in a string, and every line keeps its number.
  static func blankingCommentsAndStrings(in source: String) -> String {
    var reader = Reader(source)
    reader.read()
    return reader.output
  }

  private struct Reader {
    /// What the reader is inside. Code at the top level is the empty stack.
    enum Frame {
      case string(multiline: Bool, pounds: Int)
      case interpolation(depth: Int)
    }

    let characters: [Character]
    var index = 0
    var stack: [Frame] = []
    var output = ""

    init(_ source: String) {
      characters = Array(source)
    }

    mutating func read() {
      while index < characters.count {
        if case .string(let multiline, let pounds) = stack.last {
          readString(multiline: multiline, pounds: pounds)
        } else {
          readCode()
        }
      }
    }

    private func character(at offset: Int) -> Character? {
      let position = index + offset
      return position < characters.count ? characters[position] : nil
    }

    /// Whether `count` pound signs start at the offset.
    private func pounds(_ count: Int, at offset: Int) -> Bool {
      (0..<count).allSatisfy { character(at: offset + $0) == "#" }
    }

    private mutating func keep(_ count: Int = 1) {
      output.append(contentsOf: characters[index..<min(index + count, characters.count)])
      index += count
    }

    private mutating func blank(_ count: Int = 1) {
      for character in characters[index..<min(index + count, characters.count)] {
        output.append(character.isNewline ? character : " ")
      }
      index += count
    }

    private mutating func readString(multiline: Bool, pounds count: Int) {
      let quotes = multiline ? 3 : 1
      let closes = (0..<quotes).allSatisfy { character(at: $0) == "\"" } && pounds(count, at: quotes)
      if closes {
        keep(quotes + count)
        stack.removeLast()
      } else if character(at: 0) == "\\", pounds(count, at: 1) {
        if character(at: 1 + count) == "(" {
          blank(1 + count)
          keep()
          stack.append(.interpolation(depth: 1))
        } else {
          blank(2 + count)
        }
      } else {
        blank()
      }
    }

    private mutating func readCode() {
      let next = character(at: 1)
      switch character(at: 0) {
      case "/" where next == "/":
        while let character = character(at: 0), !character.isNewline {
          blank()
        }
      case "/" where next == "*":
        readBlockComment()
      case "\"", "#":
        readStringStart()
      case "(":
        if case .interpolation(let depth) = stack.last {
          stack[stack.count - 1] = .interpolation(depth: depth + 1)
        }
        keep()
      case ")":
        if case .interpolation(let depth) = stack.last {
          if depth == 1 {
            stack.removeLast()
          } else {
            stack[stack.count - 1] = .interpolation(depth: depth - 1)
          }
        }
        keep()
      default:
        keep()
      }
    }

    private mutating func readBlockComment() {
      var depth = 0
      repeat {
        if character(at: 0) == "/", character(at: 1) == "*" {
          depth += 1
          blank(2)
        } else if character(at: 0) == "*", character(at: 1) == "/" {
          depth -= 1
          blank(2)
        } else {
          blank()
        }
      } while depth > 0 && index < characters.count
    }

    /// Reads the start of a string literal. A pound sign that starts no literal, as in `#bundle`, is code.
    private mutating func readStringStart() {
      var count = 0
      while character(at: count) == "#" {
        count += 1
      }
      guard character(at: count) == "\"" else {
        keep(max(count, 1))
        return
      }
      let multiline = character(at: count + 1) == "\"" && character(at: count + 2) == "\""
      keep(count + (multiline ? 3 : 1))
      stack.append(.string(multiline: multiline, pounds: count))
    }
  }
}
