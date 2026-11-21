import Testing

/// Nothing sets a badge on the app icon. See `docs/screens/app-icon.md`.
///
/// SwiftUI's `.badge(_:)` on a tab or a row is inside the app, so the scan allows it.
enum AppIconBadge {
  static let patterns = [
    #"\bapplicationIconBadgeNumber\b"#: "sets the app icon badge",
    #"\bsetBadgeCount\b"#: "sets the app icon badge",
    #"\.badge\b(?!\s*\()"#: "names a notification's badge",
  ]

  static func findings(in files: [SourceFile]) -> [Finding] {
    files.flatMap { file in
      patterns.sorted { $0.key < $1.key }.flatMap { file.findings(of: $0.key, as: $0.value) }
    }
  }
}

@Suite("No app icon badge", .timeLimit(.minutes(1)))
struct AppIconBadgeTests {
  @Test("Nothing sets a badge on the app icon")
  func noBadge() throws {
    let findings = AppIconBadge.findings(in: try Repo.swiftFiles(under: Repo.shipped))
    #expect(findings.isEmpty, "\(findings.report)")
  }

  @Test(
    "The scan catches each way to set a badge",
    arguments: [
      "UIApplication.shared.applicationIconBadgeNumber = 3",
      "try await UNUserNotificationCenter.current().setBadgeCount(3)",
      "content.badge = 3",
      "try await center.requestAuthorization(options: [.alert, .badge, .sound])",
    ]
  )
  func scanCatches(source: String) {
    #expect(AppIconBadge.findings(in: [SourceFile(path: "Planted.swift", source: source)]).count == 1)
  }

  @Test("The scan allows a badge inside the app")
  func scanAllows() {
    let source = """
      Tab("Gifts", systemImage: "gift") { GiftsTab() }
        .badge(count)
      // content.badge = 3
      """
    #expect(AppIconBadge.findings(in: [SourceFile(path: "Planted.swift", source: source)]).isEmpty)
  }
}
