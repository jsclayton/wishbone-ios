import Testing

/// Every string in the package names its bundle. Without `bundle: #bundle`, SwiftUI looks in the main bundle and
/// fails with no error. See "Strings" in `docs/architecture.md`.
enum StringBundle {
  /// Calls that look up a string, in any module. Each must have `bundle: #bundle`. `LocalizedStringKey` can't
  /// name a bundle, so the rule bans it.
  static let lookups = [
    #"\b(?:Text|LocalizedStringResource|LocalizedStringKey)\s*(\()\s*#*""#,
    #"\b(?:String|AttributedString)\s*(\()\s*localized\s*:\s*#*""#,
  ]

  /// In `WishboneUI`, any call whose first argument is a string literal with no label, or an array of them, such
  /// as `Button("Add")`. SwiftUI reads such a literal as a key in the main bundle. Give the control a `Text` with
  /// a bundle instead.
  static let unlabeledLiteral = #"\b(\w+)\s*(\()\s*\[?\s*#*""#

  /// The calls in `WishboneUI` that take a string literal with no label and show no words. Each has a reason.
  static let callsThatShowNoWords = [
    "SceneStorage": "The key that a window's saved place is kept under, as in @SceneStorage(\"WindowPlace\")"
  ]

  /// In `WishboneUI`, any argument that is a string literal with a label, such as `prompt: "Search"`. SwiftUI
  /// reads it as a key in the main bundle too. Give the argument a `Text` with a bundle instead.
  static let labeledLiteral = #"([(,])\s*(\w+)\s*:\s*#*""#

  /// The labels in `WishboneUI` that take a string literal and show no words. Each has a reason.
  static let labelsThatShowNoWords = [
    "systemName": "The name of an SF Symbol, as in Image(systemName:)",
    "systemImage": "The name of an SF Symbol, as in Label(_:systemImage:)",
    "string": "A web address, as in URL(string:), which a web link opens and never shows",
  ]

  private static let bundle = #"\bbundle\s*:\s*#bundle\b"#
  private static let what = "a string with no bundle: #bundle"

  static func findings(in files: [SourceFile], isUI: (SourceFile) -> Bool) -> [Finding] {
    files.flatMap { file in
      var findings = lookups.flatMap { calls(in: file, matching: $0) }
      if isUI(file) {
        findings += calls(in: file, matching: unlabeledLiteral, skipping: Set(callsThatShowNoWords.keys))
        findings += labeledLiterals(in: file)
      }
      // A call that more than one pattern finds is one finding.
      return findings.reduce(into: [Finding]()) { unique, finding in
        if !unique.contains(finding) { unique.append(finding) }
      }
    }
  }

  /// The calls that the pattern finds and that have no `bundle: #bundle`. The pattern's last group is the call's
  /// opening parenthesis. A group before it, if any, is the name of what is called.
  private static func calls(in file: SourceFile, matching pattern: String, skipping: Set<String> = []) -> [Finding] {
    file.code.matches(of: SourceFile.regex(pattern)).compactMap { match in
      guard let open = match.output.last?.range else { return nil }
      if match.output.count > 2, let name = match.output[1].substring, skipping.contains(String(name)) {
        return nil
      }
      guard !file.arguments(openedAt: open.lowerBound).contains(SourceFile.regex(bundle)) else { return nil }
      return file.finding(at: open.lowerBound, what)
    }
  }

  /// The calls with a labeled string literal and no `bundle: #bundle`. Each finding is at the call's opening
  /// parenthesis, so that a call with two faults is one finding.
  private static func labeledLiterals(in file: SourceFile) -> [Finding] {
    file.code.matches(of: SourceFile.regex(labeledLiteral)).compactMap { match in
      guard let before = match.output[1].range, let label = match.output[2].substring else { return nil }
      guard labelsThatShowNoWords[String(label)] == nil else { return nil }
      // The label follows the call's opening parenthesis, or a comma inside the call.
      let opening = file.code[before] == "(" ? before.lowerBound : file.openingParenthesis(around: before.lowerBound)
      guard let opening else { return nil }
      guard !file.arguments(openedAt: opening).contains(SourceFile.regex(bundle)) else { return nil }
      return file.finding(at: opening, what)
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
      ##"Button(#"Scan "QR" code"#) {}"##,
      #"content.accessibilityAction(named: "Claim") { claim() }"#,
      #"content.searchable(text: $query, prompt: "Search")"#,
      """
      content.searchable(
        text: $query,
        prompt: "Search"
      )
      """,
      #"content.accessibilityInputLabels(["Scan", "QR code"])"#,
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
      #"Label { Text("Scan QR code", bundle: #bundle) } icon: { Image(systemName: "qrcode") }"#,
      #"Text("Scan QR code", bundle: #bundle, comment: "The main button")"#,
      #"String(localized: "reminder.title", defaultValue: "A birthday is soon", bundle: #bundle)"#,
      #"let label = isOn ? on : "plain""#,
      #"Text(user.name)"#,
    ]
  )
  func scanAllows(source: String) {
    let file = SourceFile(path: "Planted.swift", source: source)
    #expect(StringBundle.findings(in: [file]) { _ in true }.isEmpty)
  }
}
