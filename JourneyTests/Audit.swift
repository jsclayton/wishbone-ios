import XCTest

/// The accessibility audit of each screen that the journeys reach. See "Accessibility checks" in
/// `docs/development.md`.
///
/// Under the gate, each screen that a run's journeys reach is audited in the four settings of the audit once in
/// that run, in one run of the journey's actions. A journey asks the gate's settings helper, a small HTTP server on
/// the Mac, whether the screen is new in the run, and to put the simulator in each setting, because a test can't
/// change the text size or Increase Contrast from inside the simulator. A run from Xcode, and the gate's run in the
/// double-length pseudo-language, have no helper: a journey audits each screen each time that it reaches it, in
/// the simulator's own settings.
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

  /// The largest text size, which audits Dynamic Type on every row that shows. See `run`.
  private static let largestText = settings[1]

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
  private static let settleTimeout: Duration = .seconds(60)

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
  /// `screen` is the screen's name, and the key of the audit in the run: a screen that an earlier journey in the
  /// run audited is not audited again. So the run's time grows with the screens that it reaches, not with its
  /// journeys. Two screens with one name are one screen to the audit.
  ///
  /// An exception is allowed one at a time, here, with a reason.
  ///
  /// `rowsThatLeaveTheScreen` names the rows of a system list, by the start of their words, that a larger text
  /// pushes off the screen. The list then lets go of them, so the Dynamic Type check can't measure them, and
  /// reports them as "partially unsupported". Only that issue is allowed for them, and never at the largest text
  /// size: there the rows that show are on the screen from the start, so the check measures each of them in full.
  static func run(
    on app: XCUIApplication, showing screen: String, in test: XCTestCase, rowsThatLeaveTheScreen: [String] = []
  ) async throws {
    guard let helper else {
      // A run with no helper is at the simulator's own text size, as the double-length run is.
      try audit(app, screen, in: ownSetting, screenshot: app.screenshot(), rows: rowsThatLeaveTheScreen, test: test)
      return
    }
    guard try await isNew(screen, helper: helper) else { return }
    // Each change of setting must change the screen from what it was just before, and then the screen must be
    // still. Between two settings, the simulator goes back to the default. So the audit never reads a screen that
    // is still on its way from one setting to the next, and each change is of one setting only.
    try await apply(settings[0], helper: helper)
    var current = try await settledScreen(of: app, in: settings[0], where: { _ in true })
    try audit(
      app, screen, in: settings[0].label, screenshot: current.screenshot, rows: rowsThatLeaveTheScreen, test: test)
    for setting in settings.dropFirst() {
      try await apply(setting, helper: helper)
      let toSetting = Change(from: settings[0], before: current.pixels, helper: helper)
      let shown = try await settledScreen(of: app, in: setting, after: toSetting)
      // The largest text size gets no rows, so it checks Dynamic Type on every row that shows. See above.
      let rows = setting.name == largestText.name ? [] : rowsThatLeaveTheScreen
      try audit(app, screen, in: setting.label, screenshot: shown.screenshot, rows: rows, test: test)
      try await apply(settings[0], helper: helper)
      let toDefault = Change(from: setting, before: shown.pixels, helper: helper)
      current = try await settledScreen(of: app, in: settings[0], after: toDefault)
    }
  }

  private static func audit(
    _ app: XCUIApplication, _ screen: String, in setting: String, screenshot: XCUIScreenshot, rows: [String],
    test: XCTestCase
  ) throws {
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "\(screen), in \(setting)"
    attachment.lifetime = .keepAlways
    test.add(attachment)
    // Every issue on the screen, so one run reports all of them, not only the first.
    var issues: [String] = []
    try app.performAccessibilityAudit { issue in
      // Scan QR code is disabled where the camera is denied or not available, as in the simulator, and the words
      // beside it say why. WCAG's contrast rule leaves out a control that is not active (1.4.3, 1.4.11).
      if issue.auditType == .contrast, let scan = issue.element, scan.label == words("Scan QR code"), !scan.isEnabled {
        return true
      }
      // The system search field draws its prompt on one line, at the system's own size. The audit reports the
      // prompt as clipped also when all of it shows, and when the field holds text. The field's label is the whole
      // prompt, so VoiceOver reads it.
      if issue.auditType == .textClipped, issue.element?.elementType == .searchField { return true }
      // A row that a larger text pushes off the screen can't be measured. See `run`. In the double-length
      // pseudo-language, a row's words start with the words of English too, so the prefix still matches.
      if issue.auditType == .dynamicType, let row = issue.element?.label, rows.contains(where: row.hasPrefix) {
        return true
      }
      // Done in a sheet's bar (Settings, Share diagnostics) is the system's own bar button, on the system's glass.
      // The audit reports its text as low contrast, where its screenshot shows black on glass of about
      // (240, 240, 245), near 18:1. It reports that the text doesn't grow, where iOS shows a bar button in the large
      // content viewer instead. A label with a text style of its own changes neither. The exception is for Done in
      // a navigation bar only: the element must be the bar's Done itself, not another Done on the screen.
      if [.contrast, .dynamicType].contains(issue.auditType), let done = issue.element, done.elementType == .button,
        done.label == words("Done"),
        case let barDone = app.navigationBars.buttons[words("Done")].firstMatch, barDone.exists,
        barDone.frame == done.frame
      {
        return true
      }
      // Sign out and Continue in the profile gate's bar are the same: the system's own bar buttons, on the system's
      // glass, where the screenshot shows black text on near-white glass, and white on dark glass in dark mode.
      // The exception is for those buttons only. Continue reads "Try again" after the instance couldn't be reached.
      if [.contrast, .dynamicType].contains(issue.auditType), let button = issue.element,
        button.elementType == .button,
        let gateButton = ["Sign out", "Continue", "Try again"].map(words).first(where: { $0 == button.label }),
        app.staticTexts[words("Finish your profile")].exists,
        // The element must be the bar's button itself, not another with the same words.
        case let barButton = app.navigationBars.firstMatch.buttons[gateButton], barButton.exists,
        barButton.frame == button.frame
      {
        return true
      }
      // The element's words, its type, such as a text field, and its place, so a failure says which it is.
      let element =
        issue.element.map { "\($0.label), element type \($0.elementType.rawValue), at \($0.frame)" } ?? "no element"
      issues.append("\(issue.compactDescription) (\(element))")
      return true
    }
    if !issues.isEmpty {
      XCTFail("\(screen), in \(setting): \(issues.joined(separator: "; "))")
    }
  }

  /// How long the settings helper may take to answer. It gives each `simctl` call 30 seconds, and runs a call that
  /// hangs again while the change has time left. It never starts a call that could end after 180 seconds
  /// (`helperAnswerLimitMs` in `scripts/gate/simulator.mjs`), so it answers within that, with an error that names
  /// the call when a call keeps hanging. A gate test holds this limit above that.
  private static let helperTimeout: TimeInterval = 200

  /// Asks the settings helper whether the screen is new in the run. The helper remembers each screen that a
  /// journey named, so the first journey to name a screen audits it, and a later one doesn't.
  private static func isNew(_ screen: String, helper: URL) async throws -> Bool {
    var request = URLRequest(url: helper.appending(path: "screens"))
    request.httpMethod = "POST"
    request.httpBody = Data(screen.utf8)
    request.timeoutInterval = helperTimeout
    let (body, response) = try await URLSession.shared.data(for: request)
    switch (response as? HTTPURLResponse)?.statusCode {
    case 201: return true
    case 200: return false
    default:
      throw AuditError(
        "The settings helper didn't say whether \(screen) is new: \(String(decoding: body, as: UTF8.self))")
    }
  }

  /// Asks the settings helper to put the simulator in the setting. It answers when `simctl` has applied it.
  ///
  /// With `previous`, the helper sends the change again: it puts the simulator in `previous`, and then in the
  /// setting, so each option of the change is set once more. See `settledScreen(of:in:after:)`.
  private static func apply(_ setting: Setting, after previous: Setting? = nil, helper: URL) async throws {
    var address = helper.appending(path: "settings/\(setting.name)")
    if let previous { address.append(queryItems: [URLQueryItem(name: "after", value: previous.name)]) }
    var request = URLRequest(url: address)
    request.httpMethod = "POST"
    request.timeoutInterval = helperTimeout
    let (body, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 204 else {
      throw AuditError("The settings helper didn't apply \(setting.label): \(String(decoding: body, as: UTF8.self))")
    }
  }

  /// A change of setting that the helper applied: the setting that the simulator was in, and the screen as it was.
  private struct Change {
    let from: Setting
    let before: Data
    let helper: URL
  }

  /// How long the screen may show exactly what it showed before a change, before the change is sent again. A
  /// change shows within a few seconds, also on a slow runner.
  private static let unchangedLimit: Duration = .seconds(15)

  /// How many times a change is sent again, after the first time.
  private static let resendLimit = 2

  /// Waits until two screenshots in a row are the same, and differ from the screen before the change: the screen
  /// shows the setting, and is still.
  ///
  /// This is where the named flake "a change of setting doesn't show in the app" in `docs/development.md` is met:
  /// `simctl` applied the change, but the app goes on showing the screen as it was. So when the screen has shown
  /// exactly what it showed before for `unchangedLimit` since the change was sent, the journey asks the helper to
  /// send the change again, up to `resendLimit` times. Each send gets the whole `settleTimeout`. A screen that
  /// moved is only slow, so its change isn't sent again.
  private static func settledScreen(
    of app: XCUIApplication, in setting: Setting, after change: Change
  ) async throws -> (screenshot: XCUIScreenshot, pixels: Data) {
    var resends = 0
    while true {
      do {
        return try await settledScreen(
          of: app, in: setting, where: { $0 != change.before }, before: change.before,
          unchangedLimit: resends < resendLimit ? unchangedLimit : nil)
      } catch is Unchanged {
        resends += 1
        try await apply(setting, after: change.from, helper: change.helper)
      } catch let error as AuditError where resends > 0 {
        let times = resends == 1 ? "once" : resends == 2 ? "twice" : "\(resends) times"
        throw AuditError("\(error.description) The change was sent again \(times).")
      }
    }
  }

  /// The screen still showed exactly what it showed before a change, at the limit. See `settledScreen(of:in:after:)`.
  private struct Unchanged: Error {}

  /// Waits until two screenshots in a row are the same, and pass `accept`: the screen shows the setting, and is
  /// still. The gate holds the status bar's clock still, so a still screen gives the same pixels each time.
  ///
  /// `before` is the screen before a change. With `unchangedLimit`, it throws `Unchanged` when every screenshot
  /// was exactly `before` for that long.
  private static func settledScreen(
    of app: XCUIApplication, in setting: Setting, where accept: (Data) -> Bool, before: Data? = nil,
    unchangedLimit: Duration? = nil
  ) async throws -> (screenshot: XCUIScreenshot, pixels: Data) {
    let started = ContinuousClock.now
    let deadline = started + settleTimeout
    var last: Data?
    var moved = false
    while true {
      let screenshot = app.screenshot()
      let pixels = screenshot.pngRepresentation
      if pixels == last, accept(pixels) { return (screenshot, pixels) }
      last = pixels
      if let before, !moved {
        if pixels != before {
          moved = true
        } else if let unchangedLimit, ContinuousClock.now - started >= unchangedLimit {
          throw Unchanged()
        }
      }
      guard ContinuousClock.now < deadline else {
        let unchanged = moved || before == nil ? "" : " It showed the screen as it was before the change."
        throw AuditError("The screen didn't settle in \(setting.label) within \(settleTimeout).\(unchanged)")
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
