import CryptoKit
import Foundation
import Testing

/// The two rules that keep the local copy and its kept `ETag` true. See `LocalDatabase` in `WishboneSession`.
enum LocalCopyRules {
  static let module = Repo.module("WishboneSession")

  // MARK: - Every write goes through one place

  /// The two functions that may write to the database: the one that makes the copy's tables, and the one that
  /// every change to the copy goes through, which drops the kept `ETag` in the same change.
  ///
  /// The reminder settings' `save` writes a file of its own, beside the database and not in it, so it drops no
  /// `ETag`: the settings are not part of the copy.
  static let writers = [
    Writer(path: "\(module)/CopySchema.swift", function: "prepareCopy"),
    Writer(path: "\(module)/LocalDatabase.swift", function: "change"),
    Writer(path: "\(module)/ReminderSettingsFile.swift", function: "save"),
  ]

  struct Writer: Equatable {
    let path: String
    let function: String
  }

  /// A call that opens a write to a GRDB database.
  static let write =
    #"\.(write|writeWithoutTransaction|barrierWriteWithoutTransaction|asyncWrite|asyncWriteWithoutTransaction"#
    + #"|asyncBarrierWriteWithoutTransaction|unsafeReentrantWrite)\s*[\{\(]"#

  /// Each place that opens a write, with the function that it is in.
  static func writes(in files: [SourceFile]) -> [(writer: Writer, finding: Finding)] {
    places(of: write, in: files, "writes to the database outside change()")
  }

  /// Each place where the pattern matches, with the function that it is in, and a finding that says `what`.
  static func places(of pattern: String, in files: [SourceFile], _ what: String) -> [(writer: Writer, finding: Finding)]
  {
    files.flatMap { file in
      file.matches(of: pattern).map { match in
        let before = file.code[..<match.lowerBound]
        let function = before.matches(of: SourceFile.regex(#"\bfunc\s+(\w+)"#)).last
          .flatMap { $0.output[1].substring }.map(String.init)
        return (Writer(path: file.path, function: function ?? ""), file.finding(at: match.lowerBound, what))
      }
    }
  }

  static func findings(in files: [SourceFile]) -> [Finding] {
    writes(in: files).filter { !writers.contains($0.writer) }.map(\.finding)
  }

  // MARK: - The changes that keep the ETag

  /// The functions that may keep the `ETag` through a change: the ones of the blocked stores, which
  /// `GET /versions` doesn't cover. Any other change to the copy must drop it.
  static let outsideTheVersions = ["replaceBlockedStores", "saveBlockedStore", "removeBlockedStore"].map {
    Writer(path: "\(module)/LocalDatabase.swift", function: $0)
  }

  /// An argument that may keep the `ETag`: `isOutsideTheVersions:` with any value but `false`. The parameter's own
  /// declaration, `isOutsideTheVersions: Bool`, is not one.
  static let keepsTheETag = #"\bisOutsideTheVersions\s*:(?!\s*(false|Bool)\b)"#

  /// Each place that may keep the `ETag` through a change, with the function that it is in.
  static func changesOutsideTheVersions(in files: [SourceFile]) -> [(writer: Writer, finding: Finding)] {
    places(of: keepsTheETag, in: files, "keeps the ETag outside the blocked stores' functions")
  }

  static func etagFindings(in files: [SourceFile]) -> [Finding] {
    changesOutsideTheVersions(in: files).filter { !outsideTheVersions.contains($0.writer) }.map(\.finding)
  }

  // MARK: - The schema number rises with the copy

  /// The files that say what the copy keeps: its tables, its rows, and the values of the API that the rows keep as
  /// they are.
  static let schemaFiles = [
    "\(module)/CopySchema.swift", "\(module)/Rows.swift", Repo.module("WishboneAPI") + "/Values.swift",
  ]

  /// The parts of other files that say what the copy keeps: the kinds of the answer that the pull keeps, which
  /// bodies hold the summaries that the copy keeps, how a summary's row is made, how a row is made from the API's
  /// model, and which users each body holds as summaries (`HoldsSummaries`, with the users of a gift's flag). Each is the code from its first line up to its last, or to the end of the file. A part that
  /// can't be found fails the test, so a rename can't drop it from the digest.
  static let schemaParts = [
    Part(path: "\(module)/Pull.swift", from: "  struct Named: Sendable {", to: "  // MARK: - One kind of resource"),
    Part(
      path: "\(module)/LocalDatabase.swift", from: "  func bodiesNaming(",
      to: "  /// The version of each group in the copy"),
    Part(
      path: "\(module)/LocalDatabase.swift", from: "  private static func summaryRows<",
      to: "  /// Saves the groups"),
    Part(path: "\(module)/LocalDatabase.swift", from: "// MARK: - A row from the API's model", to: nil),
    Part(
      path: Repo.module("WishboneAPI") + "/Models.swift", from: "  public var users: [UserSummary] {",
      to: "  public static let fields"),
  ]

  struct Part {
    let path: String
    let from: String
    let to: String?

    /// The part of the source. Nil when its first or its last line is not there.
    func code(in source: String) -> String? {
      guard let start = source.range(of: from) else { return nil }
      guard let to else { return String(source[start.lowerBound...]) }
      guard let end = source.range(of: to, range: start.upperBound..<source.endIndex) else { return nil }
      return String(source[start.lowerBound..<end.lowerBound])
    }
  }

  /// The copy's schema number, and the digest of the code that it stands for.
  ///
  /// **When this fails, what the copy keeps has changed.** Raise `LocalDatabase.copySchema`, so that every device
  /// drops the old copy. Then record the new number here, with the digest that the failure gives. If only the
  /// code's own shape changed, and nothing that a database holds, record the digest alone.
  static let recorded = (schema: 5, digest: "871eec47f9321bbe")

  /// The digest of the sources: their code, with no comment line and no white space.
  static func digest(of sources: [String]) -> String {
    let code = sources.flatMap { source in
      source.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.hasPrefix("//") }
    }.joined().filter { !$0.isWhitespace }
    return SHA256.hash(data: Data(code.utf8)).prefix(8).map { byte in
      let hex = String(byte, radix: 16)
      return hex.count == 1 ? "0\(hex)" : hex
    }.joined()
  }

  /// The schema number that the source gives.
  static func schema(in source: String) -> Int? {
    source.firstMatch(of: /static let copySchema = (\d+)/).flatMap { Int($0.output.1) }
  }
}

@Suite("The local copy's rules", .timeLimit(.minutes(1)))
struct LocalCopyRulesTests {
  @Test(
    """
    Every write to the copy goes through change(), which drops the kept ETag in the same change. Only the \
    blocked stores, which GET /versions doesn't cover, keep it
    """
  )
  func writesGoThroughChange() throws {
    let files = try Repo.swiftFiles(under: [LocalCopyRules.module])
    // The scan finds the two that are allowed, so it reads the code that it holds.
    #expect(LocalCopyRules.writes(in: files).map(\.writer) == LocalCopyRules.writers)
    let findings = LocalCopyRules.findings(in: files)
    #expect(findings.isEmpty, "\(findings.report)")
    // The same for the changes that keep the ETag.
    #expect(LocalCopyRules.changesOutsideTheVersions(in: files).map(\.writer) == LocalCopyRules.outsideTheVersions)
    let keeps = LocalCopyRules.etagFindings(in: files)
    #expect(keeps.isEmpty, "\(keeps.report)")
  }

  @Test(
    "The scan catches a change that keeps the ETag outside the blocked stores' functions",
    arguments: [
      "func save() async throws {\n  try await change(isOutsideTheVersions: true) { _ in }\n}",
      "func save(keep: Bool) async throws {\n  try await change(isOutsideTheVersions: keep) { _ in }\n}",
      "func replaceBlockedStores() {}\nfunc save() async throws {\n  try await change(isOutsideTheVersions : true) { _ in }\n}",
    ]
  )
  func scanCatchesAChangeThatKeepsTheETag(source: String) {
    let file = SourceFile(path: "\(LocalCopyRules.module)/LocalDatabase.swift", source: source)
    #expect(LocalCopyRules.etagFindings(in: [file]).count == 1)
  }

  @Test("The scan allows the blocked stores, the parameter itself, false, and words in comments")
  func scanAllowsTheBlockedStores() {
    let source = """
      func change(isOutsideTheVersions: Bool = false, _ body: () -> Void) async throws {}
      func replaceBlockedStores() async throws {
        try await change(isOutsideTheVersions: true) { }
      }
      func save() async throws {
        // Not change(isOutsideTheVersions: true) here.
        try await change(isOutsideTheVersions: false) { }
      }
      """
    let file = SourceFile(path: "\(LocalCopyRules.module)/LocalDatabase.swift", source: source)
    #expect(LocalCopyRules.etagFindings(in: [file]).isEmpty)
    // The same function in another file is not the one place.
    let other = SourceFile(path: "\(LocalCopyRules.module)/SessionModel.swift", source: source)
    #expect(LocalCopyRules.etagFindings(in: [other]).count == 1)
  }

  @Test(
    "The scan catches a write outside change()",
    arguments: [
      "func save() async throws {\n  try await writer.write { database in try row.save(database) }\n}",
      "func remove() throws {\n  try writer.writeWithoutTransaction { database in try row.delete(database) }\n}",
      "func change() {}\nfunc keep() async throws {\n  try await writer.write { _ in }\n}",
      "func save() {\n  writer.asyncWrite({ database in try row.save(database) }, completion: { _, _ in })\n}",
    ]
  )
  func scanCatches(source: String) {
    let file = SourceFile(path: "\(LocalCopyRules.module)/LocalDatabase.swift", source: source)
    #expect(LocalCopyRules.findings(in: [file]).count == 1)
  }

  @Test("The scan allows the write of change() itself, a read, and words in comments and strings")
  func scanAllows() {
    let source = """
      func keptETag() async throws -> String? {
        // A read is no write: writer.write { } is not here.
        try await writer.read { database in try String.fetchOne(database, sql: "SELECT etag FROM keptETag") }
      }
      func change() async throws {
        try await writer.write { database in try database.execute(sql: "DELETE FROM keptETag") }
      }
      """
    let file = SourceFile(path: "\(LocalCopyRules.module)/LocalDatabase.swift", source: source)
    #expect(LocalCopyRules.findings(in: [file]).isEmpty)
    // The same function in another file is not the one place.
    let other = SourceFile(path: "\(LocalCopyRules.module)/SessionModel.swift", source: source)
    #expect(LocalCopyRules.findings(in: [other]).count == 1)
  }

  @Test("The copy's schema number rises with every change to what the copy keeps")
  func schemaNumberRisesWithTheCopy() throws {
    var sources = try LocalCopyRules.schemaFiles.map { try String(contentsOf: Repo.url($0), encoding: .utf8) }
    for part in LocalCopyRules.schemaParts {
      let source = try String(contentsOf: Repo.url(part.path), encoding: .utf8)
      sources.append(try #require(part.code(in: source), "\(part.path) has no part from \"\(part.from)\""))
    }
    let schema = try #require(LocalCopyRules.schema(in: sources[0]))
    let digest = LocalCopyRules.digest(of: sources)
    let recorded = LocalCopyRules.recorded
    #expect(
      schema == recorded.schema && digest == recorded.digest,
      """
      What the copy keeps has changed since copySchema \(recorded.schema) was recorded. The code now says \
      copySchema \(schema), with the digest "\(digest)".
      \(schema == recorded.schema
        ? "Raise LocalDatabase.copySchema, so that every device drops its old copy. Then run this test again."
        : "Record (schema: \(schema), digest: \"\(digest)\") in LocalCopyRules.recorded.")
      If only the code's own shape changed, and nothing that a database holds, record the digest alone.
      """
    )
  }

  @Test("The digest changes with a column and with the number, and not with a comment or with white space")
  func digestFollowsTheCode() {
    let tables = """
      static let copySchema = 2
      // The users.
      table.column("name", .text).notNull()
      """
    let digest = LocalCopyRules.digest(of: [tables])
    #expect(LocalCopyRules.schema(in: tables) == 2)
    #expect(LocalCopyRules.digest(of: [tables.replacing("// The users.", with: "  // Every user.\n")]) == digest)
    #expect(LocalCopyRules.digest(of: [tables.replacing(".notNull()", with: "\n    .notNull()")]) == digest)
    #expect(LocalCopyRules.digest(of: [tables.replacing("\"name\"", with: "\"title\"")]) != digest)
    #expect(LocalCopyRules.digest(of: [tables.replacing("copySchema = 2", with: "copySchema = 3")]) != digest)
    #expect(LocalCopyRules.digest(of: [tables, "let lastName: String?"]) != digest)
  }
}
