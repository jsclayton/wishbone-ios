import Testing

/// Every string in the package names its bundle. Without `bundle: #bundle`, SwiftUI looks in the main bundle and
/// fails with no error. See "Strings" in `docs/architecture.md`.
enum StringBundle {
  /// Calls that look up a string, in any module. Each must have `bundle: #bundle`. `LocalizedStringKey` can't
  /// name a bundle, so the rule bans it.
  static let lookups = [
    #"\b(?:Text|LocalizedStringResource|LocalizedStringKey)\s*(\()\s*""#,
    #"\b(?:String|AttributedString)\s*(\()\s*localized\s*:\s*""#,
  ]

  /// In `WishboneUI`, any call that takes a string literal with no label, such as `Button("Add")`. SwiftUI reads
  /// such a literal as a key in the main bundle. Give the control a `Text` with a bundle instead.
  static let unlabeledLiteral = #"\b(\w+)\s*(\()\s*""#

  /// The calls in `WishboneUI` that take a string literal with no label and show no words. Each has a reason.
  static let callsThatShowNoWords: [String: String] = [:]

  static func findings(in files: [SourceFile], isUI: (SourceFile) -> Bool) -> [Finding] {
    files.flatMap { file in
      var findings = lookups.flatMap { calls(in: file, matching: $0) }
      if isUI(file) {
        findings += calls(in: file, matching: unlabeledLiteral, skipping: Set(callsThatShowNoWords.keys))
      }
      // A call that both patterns find is one finding.
      return findings.reduce(into: [Finding]()) { unique, finding in
        if !unique.contains(finding) { unique.append(finding) }
      }
    }
  }

  /// The calls that the pattern finds and that have no `bundle: #bundle`. The pattern's last group is the call's
  /// opening parenthesis. A group before it, if any, is the name of what is called.
  private static func calls(in file: SourceFile, matching pattern: String, skipping: Set<String> = []) -> [Finding] {
    let bundle = SourceFile.regex(#"\bbundle\s*:\s*#bundle\b"#)
    return file.code.matches(of: SourceFile.regex(pattern)).compactMap { match in
      guard let open = match.output.last?.range else { return nil }
      if match.output.count > 2, let name = match.output[1].substring, skipping.contains(String(name)) {
        return nil
      }
      guard !file.arguments(openedAt: open.lowerBound).contains(bundle) else { return nil }
      return file.finding(at: match.range.lowerBound, "a string with no bundle: #bundle")
    }
  }
}

@Suite("Every string in the package names its bundle", .timeLimit(.minutes(1)))
struct StringBundleTests {
  @Test("Every string in the package has bundle: #bundle")
  func packageStrings() throws {
    let findings = StringBundle.findings(in: try Repo.swiftFiles(under: [Repo.modules])) {
      $0.path.hasPrefix(Repo.module("WishboneUI") + "/")
    }
    #expect(findings.isEmpty, "\(findings.report)")
  }

  @Test("The scan reads the package's strings")
  func scanReadsTheScreens() throws {
    // The signed-out screen has strings, so a scan that finds none there reads nothing.
    let screen = try Repo.swiftFiles(under: [Repo.module("WishboneUI")]).filter {
      $0.path.hasSuffix("SignedOutScreen.swift")
    }
    #expect(screen.count == 1)
    #expect(screen.allSatisfy { !$0.matches(of: StringBundle.lookups[0]).isEmpty })
  }

  @Test(
    "The scan catches a string with no bundle, in any module",
    arguments: [
      #"Text("Scan QR code")"#,
      #"Text("Signed in as \(name)")"#,
      #"String(localized: "Scan QR code")"#,
      #"String(localized: "Scan QR code", comment: "The main button")"#,
      #"LocalizedStringResource("Scan QR code")"#,
      #"let key = LocalizedStringKey("Scan QR code")"#,
      #"Text("Scan QR code", bundle: .main)"#,
      #"Text("Scan QR code", comment: "bundle: #bundle")"#,
    ]
  )
  func scanCatches(source: String) {
    let file = SourceFile(path: "Planted.swift", source: source)
    #expect(StringBundle.findings(in: [file]) { _ in false }.count == 1)
  }

  @Test(
    "The scan catches a control that takes its words as a literal, in WishboneUI",
    arguments: [
      #"Button("Scan QR code") {}"#,
      #"Label("Scan QR code", systemImage: "qrcode")"#,
      #"content.navigationTitle("Settings")"#,
      #"content.accessibilityLabel("Scan QR code")"#,
    ]
  )
  func scanCatchesControls(source: String) {
    let file = SourceFile(path: "Planted.swift", source: source)
    #expect(StringBundle.findings(in: [file]) { _ in true }.count == 1)
    #expect(StringBundle.findings(in: [file]) { _ in false }.isEmpty)
  }

  @Test(
    "The scan allows a string that names its bundle, and a call with a label",
    arguments: [
      #"Text("Scan QR code", bundle: #bundle)"#,
      """
      Text(
        "If Wishbone crashes, it sends a report (never your lists).",
        bundle: #bundle
      )
      """,
      #"String(localized: "Scan QR code", bundle: #bundle)"#,
      #"LocalizedStringResource("Signed in as \(name)", bundle: #bundle)"#,
      #"Button { scan() } label: { Text("Scan QR code", bundle: #bundle) }"#,
      #"Image(systemName: "qrcode")"#,
      #"Text(user.name)"#,
    ]
  )
  func scanAllows(source: String) {
    let file = SourceFile(path: "Planted.swift", source: source)
    #expect(StringBundle.findings(in: [file]) { _ in true }.isEmpty)
  }
}
