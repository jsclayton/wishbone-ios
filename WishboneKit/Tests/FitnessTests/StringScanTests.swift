import Testing

/// Code assembles no text. See "Languages" in `docs/spec.md`, and "Strings" in `CONTRIBUTING.md`.
enum StringScan {
  /// Banned in everything that ships.
  static let everywhere = [
    #"\bText\s*\(\s*verbatim\s*:"#: "Text(verbatim:)",
    #"\bString\s*\(\s*format\s*:"#: "String(format:)",
  ]

  /// Banned where the UI is: `WishboneUI` and the three targets. Each joins text into a UI string.
  static let inUI = [
    #"\)\s*\+\s*Text\s*\("#: "Text joined to Text",
    #""\s*\+|\+=?\s*#*""#: "a string joined with +",
    #"\.appending\s*\(\s*#*""#: "a string joined with appending()",
    #"\.joined\s*\("#: "strings joined with joined()",
  ]

  /// The short allow list: a file's path, what it may use, and why.
  static let allowList: [Allowance] = []

  struct Allowance {
    let path: String
    let what: String
    let why: String
  }

  static func findings(in files: [SourceFile], isUI: (SourceFile) -> Bool) -> [Finding] {
    files.flatMap { file in
      let patterns = everywhere.merging(isUI(file) ? inUI : [:]) { first, _ in first }
      return patterns.sorted { $0.key < $1.key }.flatMap { file.findings(of: $0.key, as: $0.value) }
    }
  }

  /// The findings that the allow list doesn't cover.
  static func notAllowed(_ findings: [Finding], by allowList: [Allowance] = allowList) -> [Finding] {
    findings.filter { finding in
      !allowList.contains { $0.path == finding.path && $0.what == finding.what }
    }
  }

  /// The allowances that cover nothing any more. Each one must go.
  static func unused(_ allowList: [Allowance] = allowList, for findings: [Finding]) -> [Allowance] {
    allowList.filter { allowance in
      !findings.contains { $0.path == allowance.path && $0.what == allowance.what }
    }
  }
}

@Suite("Code assembles no text", .timeLimit(.minutes(1)))
struct StringScanTests {
  let findings: [Finding]

  init() throws {
    let ui = Repo.targets.map { "\($0)/" } + [Repo.module("WishboneUI") + "/"]
    findings = StringScan.findings(in: try Repo.swiftFiles(under: Repo.shipped)) { file in
      ui.contains { file.path.hasPrefix($0) }
    }
  }

  @Test("No Text(verbatim:), String(format:), or joined UI text outside the allow list")
  func noAssembledText() {
    let notAllowed = StringScan.notAllowed(findings)
    #expect(notAllowed.isEmpty, "\(notAllowed.report)")
  }

  @Test("Every entry in the allow list is still in use")
  func allowListIsInUse() {
    let unused = StringScan.unused(for: findings)
    #expect(unused.isEmpty, "\(unused.map { "\($0.path): \($0.what)" })")
  }

  @Test(
    "The scan catches assembled text, in any module",
    arguments: [
      #"Text(verbatim: name)"#,
      #"let price = String(format: "%.2f", amount)"#,
    ]
  )
  func scanCatches(source: String) {
    let file = SourceFile(path: "Planted.swift", source: source)
    #expect(StringScan.findings(in: [file]) { _ in false }.count == 1)
  }

  @Test(
    "The scan catches text joined into a UI string",
    arguments: [
      #"Text(first) + Text(last)"#,
      #"let title = name + "'s profile""#,
      #"let title = "Edit " + name"#,
      ##"let title = name + #"'s profile"#"##,
      #"title += " (shared)""#,
      ##"title += #" (shared)"#"##,
      #"let title = name.appending("'s profile")"#,
      #"let people = names.joined(separator: ", ")"#,
    ]
  )
  func scanCatchesJoins(source: String) {
    let file = SourceFile(path: "Planted.swift", source: source)
    #expect(!StringScan.findings(in: [file]) { _ in true }.isEmpty)
    #expect(StringScan.findings(in: [file]) { _ in false }.isEmpty)
  }

  @Test("The scan allows whole strings and sums")
  func scanAllows() {
    let source = """
      Text("Edit \\(name)'s profile", bundle: #bundle)
      let width = base + 12
      total += 1
      let folder = root.appending(path: "Lists")
      // Text(verbatim: name) + "a" + "b"
      """
    #expect(StringScan.findings(in: [SourceFile(path: "Planted.swift", source: source)]) { _ in true }.isEmpty)
  }

  @Test("The allow list covers only what it names, and reports an entry that covers nothing")
  func allowList() {
    let file = SourceFile(path: "Sources/Hex.swift", source: #"String(format: "%02x", byte)"#)
    let found = StringScan.findings(in: [file]) { _ in false }
    let used = StringScan.Allowance(
      path: "Sources/Hex.swift", what: "String(format:)", why: "A hex digest, not UI text")
    let other = StringScan.Allowance(path: "Sources/Other.swift", what: "String(format:)", why: "Nothing uses it")
    #expect(StringScan.notAllowed(found, by: [used]).isEmpty)
    #expect(StringScan.notAllowed(found, by: [other]) == found)
    #expect(StringScan.unused([used, other], for: found).map(\.path) == ["Sources/Other.swift"])
  }
}
