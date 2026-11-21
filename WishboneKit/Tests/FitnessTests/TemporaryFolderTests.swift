import Testing

/// `ScratchDirectory` in `TestSupport` is the one place that names a temporary folder. See "Temporary folders" in
/// `docs/development.md`.
enum TemporaryFolders {
  /// The one file that may name a temporary folder.
  static let allowed = Repo.module("TestSupport") + "/ScratchDirectory.swift"

  static let patterns = [
    #"\btemporaryDirectory\b"#: "names the temporary folder",
    #"\bNSTemporaryDirectory\s*\("#: "names the temporary folder",
    #"\bmkdtemp\s*\("#: "makes a temporary folder",
  ]

  static func findings(in files: [SourceFile]) -> [Finding] {
    files.filter { $0.path != allowed }.flatMap { file in
      patterns.sorted { $0.key < $1.key }.flatMap { file.findings(of: $0.key, as: $0.value) }
    }
  }
}

@Suite("No temporary folder outside ScratchDirectory", .timeLimit(.minutes(1)))
struct TemporaryFolderTests {
  @Test("Only ScratchDirectory names a temporary folder")
  func onlyScratchDirectory() throws {
    let files = try Repo.swiftFiles(under: Repo.shipped + ["WishboneKit/Tests"])
    #expect(files.contains { $0.path == TemporaryFolders.allowed })
    let findings = TemporaryFolders.findings(in: files)
    #expect(findings.isEmpty, "\(findings.report)")
  }

  @Test(
    "The scan catches each way to name a temporary folder",
    arguments: [
      "let folder = FileManager.default.temporaryDirectory",
      "let folder = URL.temporaryDirectory.appending(path: name)",
      "let path = NSTemporaryDirectory() + name",
      "guard mkdtemp(&template) != nil else { return }",
    ]
  )
  func scanCatches(source: String) {
    #expect(TemporaryFolders.findings(in: [SourceFile(path: "Planted.swift", source: source)]).count == 1)
  }

  @Test("The scan allows ScratchDirectory's own file, and words in comments and strings")
  func scanAllows() {
    let source = """
      // FileManager.default.temporaryDirectory is banned.
      let message = "Use ScratchDirectory, not NSTemporaryDirectory() or mkdtemp()."
      let folder = try ScratchDirectory()
      """
    #expect(TemporaryFolders.findings(in: [SourceFile(path: "Planted.swift", source: source)]).isEmpty)
    let named = SourceFile(path: TemporaryFolders.allowed, source: "let base = FileManager.default.temporaryDirectory")
    #expect(TemporaryFolders.findings(in: [named]).isEmpty)
  }
}
