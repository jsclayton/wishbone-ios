import CoreGraphics
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
  /// A setting of the audit: its name for the settings helper, its words in a failure, and whether the app shows it
  /// in dark mode.
  struct Setting {
    let name: String
    let label: String
    let isDark: Bool
  }

  /// The settings of the audit. The first is the default of each. They are `settings` in
  /// `scripts/gate/simulator.mjs`.
  static let settings = [
    Setting(name: "default", label: "the default settings", isDark: false),
    Setting(name: "largest-text", label: "the largest text size", isDark: false),
    Setting(name: "dark-mode", label: "dark mode", isDark: true),
    Setting(name: "increase-contrast", label: "Increase Contrast", isDark: false),
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
  ///
  /// `rowsToScrollTo` names the rows, by the start of their words, that are below the fold at the largest text
  /// size. There, after the audit of the screen as it opens, the journey scrolls each row on the screen in turn, in
  /// the order given, and audits the screen again with the row on it. A row that is on the screen already was in
  /// the audit before. So the Dynamic Type check measures, at the largest size, each row that a larger text pushes
  /// off. A run with no helper doesn't scroll.
  static func run(
    on app: XCUIApplication, showing screen: String, in test: XCTestCase, rowsThatLeaveTheScreen: [String] = [],
    rowsToScrollTo: [String] = []
  ) async throws {
    guard let helper else {
      // A run with no helper is at the simulator's own text size, as the double-length run is.
      try await audit(
        app, screen, in: ownSetting, screenshot: app.screenshot(), rows: rowsThatLeaveTheScreen, test: test)
      return
    }
    guard try await isNew(screen, helper: helper) else { return }
    // Each change of setting must change the screen from what it was just before, and then the screen must be
    // still. Between two settings, the simulator goes back to the default. So the audit never reads a screen that
    // is still on its way from one setting to the next, and each change is of one setting only.
    try await apply(settings[0], helper: helper)
    var current = try await settledScreen(of: app, in: settings[0], where: { _ in true })
    try await audit(
      app, screen, in: settings[0].label, screenshot: current.screenshot, rows: rowsThatLeaveTheScreen, test: test)
    for setting in settings.dropFirst() {
      try await apply(setting, helper: helper)
      let toSetting = Change(from: settings[0], before: current.pixels, helper: helper)
      var shown = try await settledScreen(of: app, in: setting, after: toSetting)
      // The largest text size gets no rows, so it checks Dynamic Type on every row that shows. See above.
      let rows = setting.name == largestText.name ? [] : rowsThatLeaveTheScreen
      try await audit(app, screen, in: setting.label, screenshot: shown.screenshot, rows: rows, test: test)
      if setting.name == largestText.name {
        for row in rowsToScrollTo {
          guard let top = try await scroll(app, to: row, in: screen) else { continue }
          let scrolled = try await settledScreen(of: app, in: setting, where: { _ in true })
          // The words after the setting keep the screenshot out of the gate's count of the screen's four settings.
          // The audit is of Dynamic Type and clipped text only. The screen as it opens had the other checks, and a
          // scrolled screen has rows under the top bar, which the system fades: the contrast check reads those.
          try await audit(
            app, screen, in: "\(setting.label), scrolled to \(row)", screenshot: scrolled.screenshot, rows: [],
            types: [.dynamicType, .textClipped], underTheBar: top, test: test)
          shown = scrolled
        }
      }
      try await apply(settings[0], helper: helper)
      let toDefault = Change(from: setting, before: shown.pixels, helper: helper)
      current = try await settledScreen(of: app, in: settings[0], after: toDefault)
    }
  }

  /// How many drags may bring a row on the screen.
  private static let scrollLimit = 20

  /// Drags the screen's content up until the row's top is at the top of the content, under the navigation bar, so
  /// the row is on the screen whole. A list that stops moving before the row is in place fails. Returns the top of the content when it
  /// scrolled, or nil when the row was on the screen whole already.
  private static func scroll(_ app: XCUIApplication, to row: String, in screen: String) async throws -> CGFloat? {
    let element = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", words(row)))
      .firstMatch
    let window = app.windows.firstMatch
    // The top of the content is under the navigation bar.
    let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : window.frame.minY
    func isOnScreen() -> Bool {
      element.exists && element.frame.minY >= top - 1 && element.frame.maxY <= window.frame.maxY
    }
    if isOnScreen() { return nil }
    var stillDrags = 0
    for _ in 0..<scrollLimit {
      // A list makes a row's element only near the screen, so a row that has none yet is a long drag away.
      let distance = element.exists ? element.frame.minY - top : window.frame.height * 0.4
      if element.exists, distance < 4 {
        throw AuditError("\(row) is too tall to show whole on the screen of \(screen) at the largest text size.")
      }
      let before = element.exists ? element.frame : nil
      let screenBefore = before == nil ? app.screenshot().pngRepresentation : nil
      // A short press and a slow drag with a hold, so the list doesn't coast, and nothing is tapped. A drag moves the
      // content a little less than the finger, so the loop drags again for the rest.
      let from = window.frame.minY + window.frame.height * 0.8
      let to = max(from - distance, top + 8)
      let origin = window.coordinate(withNormalizedOffset: .zero)
      let start = origin.withOffset(CGVector(dx: window.frame.width / 2, dy: from - window.frame.minY))
      let end = origin.withOffset(CGVector(dx: window.frame.width / 2, dy: to - window.frame.minY))
      start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
      try await Task.sleep(for: .milliseconds(250))
      if isOnScreen(), element.frame.minY - top < 60 { return top }
      // The row's place tells whether the list moved: a screenshot differs while the scroll indicator fades.
      let moved =
        if let before { !element.exists || element.frame != before } else {
          app.screenshot().pngRepresentation != screenBefore
        }
      if !moved {
        // A drag can be lost on a busy machine. A list at its end doesn't move three times in a row.
        stillDrags += 1
        if stillDrags == 3 {
          if isOnScreen() { return top }
          throw AuditError("\(screen) stopped scrolling at the largest text size before \(row) was on the screen.")
        }
      } else {
        stillDrags = 0
      }
    }
    throw AuditError("\(row) wasn't on the screen of \(screen) at the largest text size after \(scrollLimit) drags.")
  }

  private static func audit(
    _ app: XCUIApplication, _ screen: String, in setting: String, screenshot: XCUIScreenshot, rows: [String],
    types: XCUIAccessibilityAuditType = .all, underTheBar contentTop: CGFloat? = nil, test: XCTestCase
  ) async throws {
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "\(screen), in \(setting)"
    attachment.lifetime = .keepAlways
    test.add(attachment)
    // Every issue on the screen, so one run reports all of them, not only the first. An audit that ran out of time
    // starts again with none: what it found before the limit is not all of the screen.
    var issues: [String] = []
    try await withRetriesAfterTimeOut("\(screen), in \(setting)") {
      issues = try performAudit(app, setting: setting, types: types, rows: rows, contentTop: contentTop)
    }
    if !issues.isEmpty {
      XCTFail("\(screen), in \(setting): \(issues.joined(separator: "; "))")
    }
  }

  /// How many times an audit that ran out of time runs again, after the first time.
  private static let auditRetryLimit = 2

  /// How long the journey waits before it runs a timed-out audit again.
  private static let auditRetryPause: Duration = .seconds(2)

  /// Whether the error is XCTest's own "Audit failed to complete in time".
  private static func isAuditTimeOut(_ error: Error) -> Bool {
    let error = error as NSError
    return error.domain == "com.apple.xcode.xctest.accessibilityAudit" && error.code == -56
  }

  /// Runs `audit`, and runs it again from the start, at most `auditRetryLimit` times, when XCTest says that it
  /// didn't complete in time.
  ///
  /// This is the named flake "an accessibility audit doesn't complete in time on a CI runner" in
  /// `docs/development.md`. XCTest gives an audit about 15 seconds, which it doesn't let a test change. On a slow
  /// runner, an audit of a still screen that takes about 5 seconds can pass that limit. Each try is a whole audit, so
  /// a screen passes only when one audit read all of it. Each retry is reported to the settings helper, so the
  /// gate's line after the run names it, and is in the log.
  private static func withRetriesAfterTimeOut(_ audited: String, _ audit: () throws -> Void) async throws {
    var retries = 0
    while true {
      do {
        try audit()
        return
      } catch let error where isAuditTimeOut(error) && retries < auditRetryLimit {
        retries += 1
        print("The audit of \(audited) didn't complete in time. It runs again (\(retries) of \(auditRetryLimit)).")
        await reportRetry(audited)
        try await Task.sleep(for: auditRetryPause)
      } catch let error where isAuditTimeOut(error) {
        throw AuditError(
          "The audit of \(audited) didn't complete in time, \(retries + 1) times in a row: \(error.localizedDescription)"
        )
      }
    }
  }

  /// Tells the settings helper that an audit ran again, so the gate's line names the flake. A run with no helper
  /// has only the line in the log. A report that doesn't arrive is not a failure: the retry is in the log too.
  private static func reportRetry(_ audited: String) async {
    guard let helper else { return }
    var request = URLRequest(url: helper.appending(path: "audit-retries"))
    request.httpMethod = "POST"
    request.httpBody = Data(audited.utf8)
    request.timeoutInterval = 10
    _ = try? await URLSession.shared.data(for: request)
  }

  /// One run of the audit. Returns each issue that no exception allows.
  private static func performAudit(
    _ app: XCUIApplication, setting: String, types: XCUIAccessibilityAuditType, rows: [String],
    contentTop: CGFloat?
  ) throws -> [String] {
    var issues: [String] = []
    try app.performAccessibilityAudit(for: types) { issue in
      // On a scrolled screen, a row that starts above the top of the content is under the top bar, partly or
      // whole. It was in the audit before the scroll, whole.
      if let contentTop, let element = issue.element, element.frame.minY < contentTop - 1 { return true }
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
      // On Acknowledgements, a package's heading is the package's own name, such as GRDB.swift, which the license
      // notice must show as it is. The audit reads a name with a file's extension as not human-readable. The
      // exception is for one word with a dot on that screen only, as a package's name is.
      if issue.auditType == .sufficientElementDescription, let heading = issue.element,
        heading.elementType == .staticText, app.navigationBars[words("Acknowledgements")].exists,
        heading.label.contains("."), !heading.label.contains(" ")
      {
        return true
      }
      // A pushed screen's inline title is the system's own label in the navigation bar, at the system's size. A long
      // title, such as Acknowledgements in the double-length pseudo-language, doesn't fit the bar, and the system
      // cuts it short. VoiceOver reads the title whole. The element must be the bar's own title, not text on the
      // screen with the same words.
      if issue.auditType == .textClipped, let title = issue.element, title.elementType == .staticText,
        case let bar = app.navigationBars.firstMatch, bar.exists, bar.identifier == title.label,
        case let barTitle = bar.staticTexts[title.label], barTitle.exists, barTitle.frame == title.frame
      {
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
      // Content that scrolls under the tab bar: at the largest text size, a screen's rows go on below the bar, and
      // the audit measures the text there against the system's glass, which a person reads only after scrolling
      // it out. The exception is for contrast only, only at the largest text size, and only for a row that goes on
      // below the bar's top edge: one that starts above the bar, or one that starts under it and goes on past the
      // bottom of the screen. Which of the two a row is depends on how long the run's names are. An element that
      // ends on the screen under the bar, such as a tab or the bar's own button, is never exempt.
      if issue.auditType == .contrast, setting == largestText.label, let element = issue.element,
        case let bar = app.tabBars.firstMatch, bar.exists, element.frame.maxY > bar.frame.minY,
        element.frame.minY < bar.frame.minY || element.frame.maxY > app.windows.firstMatch.frame.maxY
      {
        return true
      }
      // The element's words, its type, such as a text field, and its place, so a failure says which it is.
      let element =
        issue.element.map { "\($0.label), element type \($0.elementType.rawValue), at \($0.frame)" } ?? "no element"
      issues.append("\(issue.compactDescription): \(issue.detailedDescription) (\(element))")
      return true
    }
    return issues
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

  /// Waits until two screenshots in a row are the same, differ from the screen before the change, and are in the
  /// setting's appearance: the screen shows the setting, and is still.
  ///
  /// This is where the named flake "a change of setting doesn't show in the app" in `docs/development.md` is met:
  /// `simctl` applied the change, but the app goes on showing the screen as it was, or shows it late. So when no
  /// screenshot has shown the change for `unchangedLimit` since the change was sent, the journey asks the helper to
  /// send the change again, up to `resendLimit` times. A screenshot shows the change when it differs from the screen
  /// before, in the setting's appearance. Each send gets the whole `settleTimeout`. A screen that showed the change
  /// is only slow, so its change isn't sent again.
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

  /// No screenshot showed the change, at the limit. See `settledScreen(of:in:after:)`.
  private struct Unchanged: Error {}

  /// Waits until two screenshots in a row are the same, pass `accept`, and are in the setting's appearance (see
  /// `isInAppearance`): the screen shows the setting, and is still. The gate holds the status bar's clock still, so
  /// a still screen gives the same pixels each time.
  ///
  /// A change of appearance can reach the app seconds after `simctl` returns, and then the app fades from one
  /// appearance to the other. On 2026-11-22, the change from dark mode back to the default reached the app 6 seconds
  /// late. Its screen in dark mode differed a little from the screenshot before the change, so a check of "differs"
  /// alone took it as the default. Increase Contrast was then audited on the screen in dark mode, and the fade to
  /// light came during the audit: the contrast check measured grey text on grey. So the appearance is checked too.
  ///
  /// `before` is the screen before a change. With `unchangedLimit`, it throws `Unchanged` when no screenshot
  /// showed the change for that long: each was exactly `before`, or not in the setting's appearance.
  private static func settledScreen(
    of app: XCUIApplication, in setting: Setting, where accept: (Data) -> Bool, before: Data? = nil,
    unchangedLimit: Duration? = nil
  ) async throws -> (screenshot: XCUIScreenshot, pixels: Data) {
    let started = ContinuousClock.now
    let deadline = started + settleTimeout
    var last: Data?
    var moved = false
    var inAppearance = false
    var onlyBefore = true
    while true {
      let screenshot = app.screenshot()
      let pixels = screenshot.pngRepresentation
      let shows = isInAppearance(screenshot, of: setting)
      if pixels == last, shows, accept(pixels) { return (screenshot, pixels) }
      last = pixels
      inAppearance = inAppearance || shows
      if let before, !moved {
        if pixels != before { onlyBefore = false }
        if pixels != before, shows {
          moved = true
        } else if let unchangedLimit, ContinuousClock.now - started >= unchangedLimit {
          throw Unchanged()
        }
      }
      guard ContinuousClock.now < deadline else {
        let unchanged =
          if moved || before == nil {
            inAppearance ? "" : " It never showed \(setting.isDark ? "dark" : "light") appearance."
          } else if onlyBefore {
            " It showed the screen as it was before the change."
          } else {
            " It never showed the change in \(setting.isDark ? "dark" : "light") appearance."
          }
        throw AuditError("The screen didn't settle in \(setting.label) within \(settleTimeout).\(unchanged)")
      }
      try await Task.sleep(for: .milliseconds(250))
    }
  }
}

extension Audit {
  /// The mean brightness, from 0 to 1, below which a screenshot is in dark mode, and above which it is light. In the
  /// screenshots of every audited screen on 2026-11-22, light was 0.87 or more and dark 0.17 or less, also with a
  /// sheet, at the largest text size, and in Increase Contrast. The fade from one to the other takes about a third
  /// of a second, and most of it is in the gap between the two limits, so a screenshot in the middle of it is
  /// neither.
  private static let darkBelow = 0.25
  private static let lightAbove = 0.8

  /// Whether the screenshot is in the setting's appearance: dark in dark mode, light in each other setting.
  static func isInAppearance(_ screenshot: XCUIScreenshot, of setting: Setting) -> Bool {
    guard let brightness = brightness(of: screenshot) else { return false }
    return setting.isDark ? brightness < darkBelow : brightness > lightAbove
  }

  /// The mean brightness of the screenshot, from 0 for black to 1 for white, from a small copy of it in grey.
  private static func brightness(of screenshot: XCUIScreenshot) -> Double? {
    guard let image = screenshot.image.cgImage else { return nil }
    let width = 24
    let height = 52
    var pixels = [UInt8](repeating: 0, count: width * height)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return false }
      context.interpolationQuality = .medium
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return nil }
    return Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count * 255)
  }
}

/// A failure of the audit's own machinery, not an issue that the audit found.
struct AuditError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
