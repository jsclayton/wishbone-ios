import XCTest

/// The accessibility audit that every journey runs on each screen it reaches. See "Accessibility checks" in
/// `docs/development.md`.
enum Audit {
  /// The setting that the gate put the simulator in for this run, such as "dark mode". A run from Xcode has none:
  /// it audits in the simulator's own settings.
  static let setting = ProcessInfo.processInfo.environment["WISHBONE_AUDIT_SETTING"] ?? "the simulator's settings"

  /// Whether the gate asked for the double-length pseudo-language, in which iOS shows each string of the String
  /// Catalog twice. Text that is cut short then fails the audit, and text that is not in the catalog stays single.
  static let isDoubleLength = ProcessInfo.processInfo.environment["WISHBONE_DOUBLE_LENGTH"] == "YES"

  /// The app to launch, in the language that the gate asked for.
  static func app() -> XCUIApplication {
    let app = XCUIApplication()
    if isDoubleLength { app.launchArguments += ["-NSDoubleLocalizedStrings", "YES"] }
    return app
  }

  /// The words of the app as the run shows them: twice in the double-length pseudo-language. What comes from the
  /// instance, such as a title, is never doubled, so a journey doesn't pass it through here.
  static func words(_ words: String) -> String {
    isDoubleLength ? "\(words) \(words)" : words
  }

  /// Attaches a screenshot of the screen that shows, and runs the audit on it. Any issue fails.
  ///
  /// An exception is allowed one at a time, here, with a reason.
  static func run(on app: XCUIApplication, showing screen: String, in test: XCTestCase) throws {
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "\(screen), in \(setting)"
    screenshot.lifetime = .keepAlways
    test.add(screenshot)
    try app.performAccessibilityAudit { issue in
      let element = issue.element?.label ?? "no element"
      XCTFail("\(screen), in \(setting): \(issue.compactDescription) (\(element))")
      return true
    }
  }
}
