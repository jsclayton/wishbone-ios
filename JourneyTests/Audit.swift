import XCTest

/// The accessibility audit that every journey runs on each screen it reaches. See "Accessibility checks" in
/// `docs/development.md`.
///
/// Under the gate, a journey audits each screen in the four settings of the audit, in one run of its actions. It
/// asks the gate's settings helper, a small HTTP server on the Mac, to put the simulator in each setting, because a
/// test can't change the text size or Increase Contrast from inside the simulator. A run from Xcode has no helper:
/// it audits once, in the simulator's own settings.
enum Audit {
  /// A setting of the audit: its name for the settings helper, and its words in a failure.
  struct Setting {
    let name: String
    let label: String
  }

  /// The settings of the audit. The first is the default of each. They are `settings` in
  /// `scripts/gate/simulator.mjs`.
  static let settings = [
    Setting(name: "default", label: "the default settings"),
    Setting(name: "largest-text", label: "the largest text size"),
    Setting(name: "dark-mode", label: "dark mode"),
    Setting(name: "increase-contrast", label: "Increase Contrast"),
  ]

  /// The gate's settings helper, such as `http://127.0.0.1:50123`. A run from Xcode, and the gate's run in the
  /// double-length pseudo-language, have none.
  static let helper: URL? = ProcessInfo.processInfo.environment["WISHBONE_SETTINGS_HELPER"].flatMap { address in
    address.isEmpty ? nil : URL(string: address)
  }

  /// Whether the gate asked for the double-length pseudo-language, in which iOS shows each string of the String
  /// Catalog twice. Text that is cut short then fails the audit, and text that is not in the catalog stays single.
  static let isDoubleLength = ProcessInfo.processInfo.environment["WISHBONE_DOUBLE_LENGTH"] == "YES"

  /// The words of the setting that a run with no helper audits in.
  private static let ownSetting = isDoubleLength ? "the double-length pseudo-language" : "the simulator's settings"

  /// How long the screen may take to show a setting.
  private static let settleTimeout: Duration = .seconds(20)

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

  /// Runs the audit on the screen that shows, in each setting, and attaches a screenshot of it in each. Any issue
  /// fails. The simulator is in the default settings again when it returns.
  ///
  /// An exception is allowed one at a time, here, with a reason.
  static func run(on app: XCUIApplication, showing screen: String, in test: XCTestCase) async throws {
    guard let helper else {
      try audit(app, screen, in: ownSetting, screenshot: app.screenshot(), test: test)
      return
    }
    // The screen in the default settings. Each other setting must change it, and then the screen must come back
    // to it, so the audit never reads a screen that is still on its way from one setting to the next.
    try await apply(settings[0], helper: helper)
    let base = try await settledScreen(of: app, in: settings[0], where: { _ in true })
    try audit(app, screen, in: settings[0].label, screenshot: base.screenshot, test: test)
    for setting in settings.dropFirst() {
      try await apply(setting, helper: helper)
      let shown = try await settledScreen(of: app, in: setting, where: { $0 != base.pixels })
      try audit(app, screen, in: setting.label, screenshot: shown.screenshot, test: test)
      try await apply(settings[0], helper: helper)
      _ = try await settledScreen(of: app, in: settings[0], where: { $0 == base.pixels })
    }
  }

  private static func audit(
    _ app: XCUIApplication, _ screen: String, in setting: String, screenshot: XCUIScreenshot, test: XCTestCase
  ) throws {
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "\(screen), in \(setting)"
    attachment.lifetime = .keepAlways
    test.add(attachment)
    try app.performAccessibilityAudit { issue in
      let element = issue.element?.label ?? "no element"
      XCTFail("\(screen), in \(setting): \(issue.compactDescription) (\(element))")
      return true
    }
  }

  /// Asks the settings helper to put the simulator in the setting. It answers when `simctl` has applied it.
  private static func apply(_ setting: Setting, helper: URL) async throws {
    var request = URLRequest(url: helper.appending(path: "settings/\(setting.name)"))
    request.httpMethod = "POST"
    let (body, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 204 else {
      throw AuditError("The settings helper didn't apply \(setting.label): \(String(decoding: body, as: UTF8.self))")
    }
  }

  /// Waits until two screenshots in a row are the same, and pass `accept`: the screen shows the setting, and is
  /// still. The gate holds the status bar's clock still, so a still screen gives the same pixels each time.
  private static func settledScreen(
    of app: XCUIApplication, in setting: Setting, where accept: (Data) -> Bool
  ) async throws -> (screenshot: XCUIScreenshot, pixels: Data) {
    let deadline = ContinuousClock.now + settleTimeout
    var last: Data?
    while true {
      let screenshot = app.screenshot()
      let pixels = screenshot.pngRepresentation
      if pixels == last, accept(pixels) { return (screenshot, pixels) }
      last = pixels
      guard ContinuousClock.now < deadline else {
        throw AuditError("The screen didn't settle in \(setting.label) within \(settleTimeout).")
      }
      try await Task.sleep(for: .milliseconds(250))
    }
  }
}

/// A failure of the audit's own machinery, not an issue that the audit found.
struct AuditError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
