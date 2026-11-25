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

  /// How many days on a journey person's birthday is, from the run's date, in UTC. It is far past Home's 60 days, so
  /// a journey that reaches Home sees the same screen on every date. The builder's own birthday, 15 June, is in
  /// Home's 60 days from 16 April each year.
  static let farOff = 180

  /// The words of the setting that a run with no helper audits in.
  private static let ownSetting = isDoubleLength ? "the double-length pseudo-language" : "the simulator's settings"

  /// How long the screen may take to show a setting.
  private static let settleTimeout: Duration = .seconds(60)

  /// The app to launch, in the language that the gate asked for, on the US storefront. StoreKit gives the
  /// simulator's storefront late, or not at all, so with its own, Settings would show the Support Wishbone rows
  /// in some runs and not others, and they could come in after the journey looked for them.
  static func app() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["WISHBONE_JOURNEY_STOREFRONT"] = "USA"
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
      // A run with no helper is at the simulator's own text size, as the double-length run is. It too waits for a
      // still screen: a journey calls the audit as soon as the screen's first element shows, often in the push or
      // the sheet that brings the screen, and the Dynamic Type check reads text that is still moving as partly
      // unsupported. On 2026-11-23, in CI run 45280072592 attempt 2, the double-length run audited Acknowledgements
      // just after its push, and the check called eight of its texts partially unsupported. The push was most likely
      // the cause: no screenshot showed it, and a wait for a still screen meets the flake either way.
      let shown = try await stillScreen(of: app, screen, in: ownSetting)
      try await audit(
        app, screen, in: ownSetting, screenshot: shown.screenshot, rows: rowsThatLeaveTheScreen, test: test)
      return
    }
    guard try await isNew(screen, helper: helper) else { return }
    // Each change of setting must change the screen from what it was just before, and then the screen must be
    // still. Between two settings, the simulator goes back to the default. So the audit never reads a screen that
    // is still on its way from one setting to the next, and each change is of one setting only.
    try await apply(settings[0], helper: helper)
    var current = try await settledScreen(of: app, screen, in: settings[0], where: { _ in true })
    try await audit(
      app, screen, in: settings[0].label, screenshot: current.screenshot, rows: rowsThatLeaveTheScreen, test: test)
    for setting in settings.dropFirst() {
      try await apply(setting, helper: helper)
      let toSetting = Change(from: settings[0], before: current.pixels, helper: helper)
      var shown = try await settledScreen(of: app, screen, in: setting, after: toSetting)
      if setting.name == largestText.name {
        // The largest text size gets no rows, so it checks Dynamic Type on every row that shows. See above.
        shown = try await auditAtLargestText(app, screen, shown: shown, test: test)
        for row in rowsToScrollTo {
          guard let top = try await scroll(app, to: row, in: screen) else { continue }
          let scrolled = try await settledScreen(of: app, screen, in: setting, where: { _ in true })
          // The words after the setting keep the screenshot out of the gate's count of the screen's four settings.
          // The audit is of Dynamic Type and clipped text only. The screen as it opens had the other checks, and a
          // scrolled screen has rows under the top bar, which the system fades: the contrast check reads those.
          try await audit(
            app, screen, in: "\(setting.label), scrolled to \(row)", screenshot: scrolled.screenshot, rows: [],
            types: [.dynamicType, .textClipped], underTheBar: top, test: test)
          shown = scrolled
        }
      } else {
        try await audit(
          app, screen, in: setting.label, screenshot: shown.screenshot, rows: rowsThatLeaveTheScreen, test: test)
      }
      try await apply(settings[0], helper: helper)
      let toDefault = Change(from: setting, before: shown.pixels, helper: helper)
      current = try await settledScreen(of: app, screen, in: settings[0], after: toDefault)
    }
  }

  /// Audits the screen at the largest text size: first the Dynamic Type check on its own, then every other check,
  /// on the screen when it is still again. Returns the screen as the second audit read it.
  ///
  /// This is the journey's answer to the named flake "an audit's issue has no element" in `docs/development.md`.
  /// In a gate run on 2026-11-25, each screen with a large title, the first time it was audited at the largest text
  /// size, had its navigation bar at 106 points, a height that isn't its own at that size. The bar's title, the
  /// segmented control and the text that the journey logged below them showed whole, each in its element's frame.
  /// The Dynamic Type check changes the app's text size during the audit, and the bar measured itself again: after
  /// the audit, it was 127 points tall, and the screen below it 21 points lower. On the three screens of the Gifts
  /// tab, which have the segmented control under the bar, the element detection check gave two issues of
  /// "Potentially inaccessible text" with no element in the first audit, on the short bar. The audit after it, on
  /// the bar at 127 points, passed. The issue most likely comes with the short bar. With the Dynamic Type check
  /// first, the other checks read the screen with the bar at its own height.
  ///
  /// The second audit's screenshot has words after the setting, so it is not one of the screen's four in the gate's
  /// count.
  private static func auditAtLargestText(
    _ app: XCUIApplication, _ screen: String, shown: (screenshot: XCUIScreenshot, pixels: Data), test: XCTestCase
  ) async throws -> (screenshot: XCUIScreenshot, pixels: Data) {
    try await audit(
      app, screen, in: largestText.label, screenshot: shown.screenshot, rows: [], types: .dynamicType, test: test)
    let settled = try await settledScreen(of: app, screen, in: largestText, where: { _ in true })
    try await audit(
      app, screen, in: largestText.label, screenshot: settled.screenshot, rows: [],
      types: XCUIAccessibilityAuditType.all.subtracting(.dynamicType), test: test,
      attachedAs: "\(screen), in \(largestText.label), after the Dynamic Type check")
    return settled
  }

  /// How many drags may bring a row on the screen.
  private static let scrollLimit = 20

  /// How far under the top of the content a drag down puts a row whose top went past it.
  private static let overshootMargin: CGFloat = 20

  /// Drags the screen's content up, and back down when a drag took the row too far, until the row's top is near the
  /// top of the content, under the navigation bar, so the row is on the screen whole. A list that stops moving
  /// before the row is in place fails. Returns the top of the content when it scrolled, or nil when the row was on
  /// the screen whole already.
  ///
  /// After each drag, it waits for a still screen before it reads the row's place. A drag on a slow runner can let the
  /// list coast: on 2026-11-24, in CI run 45292582179 attempt 2, a drag of 69 points moved the help sheet's list about
  /// 150, and the list went on moving for seconds. A read 250 milliseconds after the drag found the row on its way,
  /// and the next read found it past the top of the content, which the journey then called too tall. A row past the
  /// top is dragged back down. A row is too tall only when its top is at the top of the content and its bottom is
  /// still below the screen.
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
    let shown = "\(screen), scrolled to \(row)"
    for _ in 0..<scrollLimit {
      // A list makes a row's element only near the screen, so a row that has none yet is a long drag away. A row
      // whose top is past the top of the content went too far: the drag is down, to put its top a little under the
      // top of the content, so the drag is long enough to move the list.
      let offset = element.exists ? element.frame.minY - top : nil
      let distance = offset.map { $0 < -1 ? $0 - overshootMargin : $0 } ?? window.frame.height * 0.4
      // When the row's top is at the top of the content, the row is on the screen whole, or its bottom is below the
      // screen and it is too tall.
      if let offset, offset >= -1, offset < 4 {
        if isOnScreen() { return top }
        throw AuditError("\(row) is too tall to show whole on the screen of \(screen) at the largest text size.")
      }
      let before = element.exists ? element.frame : nil
      var screenBefore: Data?
      if before == nil {
        screenBefore = try await Screenshot.take(of: app, showing: shown).screenshot.pngRepresentation
      }
      // A short press and a slow drag with a hold, so the list doesn't coast, and nothing is tapped. A drag moves the
      // content a little less than the finger, so the loop drags again for the rest. A drag down starts under the top
      // of the content.
      let from = distance > 0 ? window.frame.minY + window.frame.height * 0.8 : top + 8
      let to = distance > 0 ? max(from - distance, top + 8) : min(from - distance, window.frame.maxY - 8)
      let origin = window.coordinate(withNormalizedOffset: .zero)
      let start = origin.withOffset(CGVector(dx: window.frame.width / 2, dy: from - window.frame.minY))
      let end = origin.withOffset(CGVector(dx: window.frame.width / 2, dy: to - window.frame.minY))
      start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
      // The list can coast after the drag all the same, so the row's place is read when the screen is still.
      let after = try await stillScreen(of: app, shown, in: largestText.label)
      if isOnScreen(), element.frame.minY - top < 60 { return top }
      // The row's place tells whether the list moved. With no row yet, the still screen does.
      let moved = if let before { !element.exists || element.frame != before } else { after.pixels != screenBefore }
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
    types: XCUIAccessibilityAuditType = .all, underTheBar contentTop: CGFloat? = nil, test: XCTestCase,
    attachedAs name: String? = nil
  ) async throws {
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name ?? "\(screen), in \(setting)"
    attachment.lifetime = .keepAlways
    test.add(attachment)
    // Every issue on the screen, so one run reports all of them, not only the first. An audit that ran out of time
    // starts again with none: what it found before the limit is not all of the screen.
    let audited = "\(screen), in \(setting)"
    var issues: [String] = []
    var lostElements = 0
    var partlyScaling = 0
    var lostRetries = 0
    var partlyScalingRetries = 0
    // How many tries in a row, up to the last, had only issues of that kind. A try with no element on any issue
    // and a try with only partly scaling text can come one after the other, so a count of retries is not a count
    // of tries in a row. An issue is never of both kinds, so at most one of the two is above zero.
    var onlyLostInARow = 0
    var onlyPartlyScalingInARow = 0
    var tries = 0
    while true {
      try await withRetriesAfterTimeOut(audited) {
        (issues, lostElements, partlyScaling) = try performAudit(
          app, setting: setting, types: types, rows: rows, contentTop: contentTop)
      }
      tries += 1
      // An issue with no element has no place, so a screenshot just after the audit shows what was on the screen
      // when the journey read it: on 2026-11-23, the Family heading under the tab bar. Its name doesn't end with
      // the setting, so it is not one of the screen's four in the gate's count. It is a diagnostic only, so a
      // screenshot that XCTest doesn't get never fails the run.
      let shown = "\(audited), at an issue with no element (try \(tries))"
      if lostElements > 0, let taken = try? await Screenshot.take(of: app, showing: shown) {
        let attachment = XCTAttachment(screenshot: taken.screenshot)
        attachment.name = shown
        attachment.lifetime = .keepAlways
        test.add(attachment)
      }
      onlyLostInARow = lostElements > 0 && lostElements == issues.count ? onlyLostInARow + 1 : 0
      onlyPartlyScalingInARow = partlyScaling > 0 && partlyScaling == issues.count ? onlyPartlyScalingInARow + 1 : 0
      // Only an audit whose every issue has no element runs again. An issue with an element is real, and a retry
      // whose audit missed it would hide it, so an audit with one fails at once.
      if lostElements > 0, lostElements == issues.count, lostRetries < lostElementRetryLimit {
        lostRetries += 1
        // The issues go in the log, so a retry that then fails in another way, such as a screen that didn't
        // settle, still shows what caused it.
        print(
          "The audit of \(audited) named an element that was gone from the screen. It runs again "
            + "(\(lostRetries) of \(lostElementRetryLimit)). Its issues: \(issues.joined(separator: "; "))")
        await reportRetry(audited, at: "lost-element-retries")
        try await Task.sleep(for: auditRetryPause)
        continue
      }
      // Only an audit whose every issue is text that the Dynamic Type check calls partially unsupported runs again,
      // on the screen when it is still. Any other issue fails at once. See `partlyScalingRetryLimit`.
      if partlyScaling > 0, partlyScaling == issues.count, partlyScalingRetries < partlyScalingRetryLimit {
        partlyScalingRetries += 1
        print(
          "The audit of \(audited) called only text that scales partially unsupported. It runs again "
            + "(\(partlyScalingRetries) of \(partlyScalingRetryLimit)). Its issues: \(issues.joined(separator: "; "))")
        await reportRetry(audited, at: "partly-scaling-retries")
        try await Task.sleep(for: auditRetryPause)
        _ = try await stillScreen(of: app, screen, in: setting)
        continue
      }
      break
    }
    if !issues.isEmpty {
      // Each suffix counts only the tries in a row whose every issue was of its kind, up to the last. A last try
      // with a mix of issues gets neither: the log names the issues of each retry.
      let lost =
        onlyLostInARow > 1
        ? " The audit named an element that wasn't on the screen \(onlyLostInARow) times in a row." : ""
      let partly =
        onlyPartlyScalingInARow > 1
        ? " The audit called the text partially unsupported \(onlyPartlyScalingInARow) times in a row." : ""
      XCTFail("\(audited): \(issues.joined(separator: "; "))\(lost)\(partly)")
    }
  }

  /// XCTest's words for text whose font grows at some of the Dynamic Type check's sizes and not at others.
  private static let partlyScalingWords = "Dynamic Type font sizes are partially unsupported"

  /// How many times an audit runs again, after the first time, when every issue that no exception allows is text,
  /// with its element, that the Dynamic Type check calls partially unsupported.
  ///
  /// This is the named flake "the Dynamic Type check calls text that scales partially unsupported" in
  /// `docs/development.md`. The check changes the app's text size itself, during the audit, and measures each text
  /// at each size. On a slow CI runner it has called text partially unsupported on a still screen whose text scales,
  /// and the next run passed the same screen: on 2026-11-23, in CI run 45232630796 attempt 1, the add form's title
  /// and notes fields, at the largest text size. Text that doesn't scale gives the issue in every audit, so it still
  /// fails: each try is a whole audit, of the screen when it is still. An audit with any other issue fails at once,
  /// so a retry never hides it. Each retry is reported to the settings helper, so the gate's line after the run
  /// names it, and is in the log.
  private static let partlyScalingRetryLimit = 2

  /// Waits until two screenshots in a row are the same, in any appearance: the screen is still. `setting` is the
  /// words of the setting, for a failure.
  private static func stillScreen(
    of app: XCUIApplication, _ screen: String, in setting: String
  ) async throws -> (screenshot: XCUIScreenshot, pixels: Data) {
    try await settledScreen(of: app, screen, in: setting, appearance: nil, where: { _ in true })
  }

  /// How many times an audit runs again, after the first time, when every issue that no exception allows has no
  /// element.
  ///
  /// This is the named flake "an audit's issue has no element" in `docs/development.md`. The audit reports an
  /// issue with its element, and the journey reads the element after the audit, to see whether an exception allows
  /// it. When the element is gone from the screen by then, as a row under the tab bar can be, XCUI gives none, and
  /// no exception can tell what it was. Each try is a whole audit, so a screen passes only when one audit gave every
  /// issue with its element, or none. An issue with no element in every try still fails, and an audit with any
  /// issue that has an element fails at once, so a retry never hides it. Each retry is reported to
  /// the settings helper, so the gate's line after the run names it, and is in the log.
  private static let lostElementRetryLimit = 2

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
        await reportRetry(audited, at: "audit-retries")
        try await Task.sleep(for: auditRetryPause)
      } catch let error where isAuditTimeOut(error) {
        throw AuditError(
          "The audit of \(audited) didn't complete in time, \(retries + 1) times in a row: \(error.localizedDescription)"
        )
      }
    }
  }

  /// Tells the settings helper that an audit ran again, at the path of its flake, so the gate's line names the flake.
  /// A run with no helper has only the line in the log. A report that doesn't arrive is not a failure: the retry is
  /// in the log too.
  private static func reportRetry(_ audited: String, at path: String) async {
    guard let helper else { return }
    var request = URLRequest(url: helper.appending(path: path))
    request.httpMethod = "POST"
    request.httpBody = Data(audited.utf8)
    request.timeoutInterval = 10
    _ = try? await URLSession.shared.data(for: request)
  }

  /// One run of the audit. Returns each issue that no exception allows, how many of them have no element, and how
  /// many are text, with its element, that the Dynamic Type check calls partially unsupported.
  private static func performAudit(
    _ app: XCUIApplication, setting: String, types: XCUIAccessibilityAuditType, rows: [String],
    contentTop: CGFloat?
  ) throws -> (issues: [String], lostElements: Int, partlyScaling: Int) {
    var issues: [String] = []
    var lostElements = 0
    var partlyScaling = 0
    let hasCutLink = contentTop.map { hasLinkCut(by: $0, in: app) } ?? false
    try app.performAccessibilityAudit(for: types) { issue in
      // Each read of an issue's element is a query of the app, so the closure reads it once.
      let element = issue.element
      // On a scrolled screen, a row that starts above the top of the content is under the top bar, partly or
      // whole. It was in the audit before the scroll, whole.
      if let contentTop, let element, element.frame.minY < contentTop - 1 { return true }
      // On a scrolled screen, while a link inside a line of text shows in part only, under a bar or off the screen's
      // edge, the audit reports Dynamic Type and clipped text issues with no element: the link's runs, which XCUI
      // doesn't give as elements. On a person's page at the largest text size, scrolled to the link's row, the line's
      // link is under the navigation bar, and it gives several of each. The exception is for those two types with no
      // element, and only while a link is cut so. Any other scrolled screen keeps every issue.
      if element == nil, [.dynamicType, .textClipped].contains(issue.auditType), hasCutLink { return true }
      // Scan QR code is disabled where the camera is denied or not available, as in the simulator, and the words
      // beside it say why. WCAG's contrast rule leaves out a control that is not active (1.4.3, 1.4.11).
      if issue.auditType == .contrast, let scan = element, scan.label == words("Scan QR code"), !scan.isEnabled {
        return true
      }
      // The system search field draws its prompt on one line, at the system's own size. The audit reports the
      // prompt as clipped also when all of it shows, and when the field holds text. The field's label is the whole
      // prompt, so VoiceOver reads it.
      if issue.auditType == .textClipped, element?.elementType == .searchField { return true }
      // A row that a larger text pushes off the screen can't be measured. See `run`. In the double-length
      // pseudo-language, a row's words start with the words of English too, so the prefix still matches.
      if issue.auditType == .dynamicType, let row = element?.label, rows.contains(where: row.hasPrefix) {
        return true
      }
      // On Acknowledgements, a package's heading is the package's own name, such as GRDB.swift, which the license
      // notice must show as it is. The audit reads a name with a file's extension as not human-readable. The
      // exception is for one word with a dot on that screen only, as a package's name is.
      if issue.auditType == .sufficientElementDescription, let heading = element,
        heading.elementType == .staticText, app.navigationBars[words("Acknowledgements")].exists,
        heading.label.contains("."), !heading.label.contains(" ")
      {
        return true
      }
      // A pushed screen's inline title is the system's own label in the navigation bar, at the system's size. A long
      // title, such as Acknowledgements in the double-length pseudo-language, doesn't fit the bar, and the system
      // cuts it short. VoiceOver reads the title whole. The element must be the bar's own title, not text on the
      // screen with the same words.
      if issue.auditType == .textClipped, let title = element, title.elementType == .staticText,
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
      if [.contrast, .dynamicType].contains(issue.auditType), let done = element, done.elementType == .button,
        done.label == words("Done"),
        case let barDone = app.navigationBars.buttons[words("Done")].firstMatch, barDone.exists,
        barDone.frame == done.frame
      {
        return true
      }
      // Sign out and Continue in the profile gate's bar are the same: the system's own bar buttons, on the system's
      // glass, where the screenshot shows black text on near-white glass, and white on dark glass in dark mode.
      // The exception is for those buttons only. Continue reads "Try again" after the instance couldn't be reached.
      if [.contrast, .dynamicType].contains(issue.auditType), let button = element,
        button.elementType == .button,
        let gateButton = ["Sign out", "Continue", "Try again"].map(words).first(where: { $0 == button.label }),
        app.staticTexts[words("Finish your profile")].exists,
        // The element must be the bar's button itself, not another with the same words.
        case let barButton = app.navigationBars.firstMatch.buttons[gateButton], barButton.exists,
        barButton.frame == button.frame
      {
        return true
      }
      // Add in the add form's bar is the same: the system's own bar button, on the system's glass. The exception is
      // for that button only, while the add form shows.
      if [.contrast, .dynamicType].contains(issue.auditType), let button = element,
        button.elementType == .button, button.label == words("Add"),
        case let form = app.navigationBars[words("Add item")], form.exists,
        // The element must be the bar's button itself, not the back button, which reads "Add" too.
        form.buttons.matching(NSPredicate(format: "label == %@", words("Add"))).allElementsBoundByIndex.contains(
          where: { $0.frame == button.frame })
      {
        return true
      }
      // Content that scrolls under the tab bar: a screen's rows go on below the bar, and the audit measures the text
      // there against the system's glass, which a person reads only after scrolling it out. The exception is for
      // contrast only, and only for a row that goes on below the bar's top edge. At the largest text size, that is
      // one that starts above the bar, or one that starts under it and goes on past the bottom of the screen. Which
      // of the two a row is depends on how long the run's names are. In the other settings, it is only a row that
      // starts above the bar: a long screen, such as Home, has its last row there. An element that ends on the
      // screen under the bar, such as a tab or the bar's own button, is never exempt.
      if issue.auditType == .contrast, let element,
        case let bar = app.tabBars.firstMatch, bar.exists, element.frame.maxY > bar.frame.minY,
        element.frame.minY < bar.frame.minY
          || (setting == largestText.label && element.frame.maxY > app.windows.firstMatch.frame.maxY)
      {
        return true
      }
      // The element's words, its type, such as a text field, and its place, so a failure says which it is.
      // An issue with no element is one that XCUI can't place: its element went from the screen between the audit
      // and this read. The audit runs again. See `audit`.
      if element == nil { lostElements += 1 }
      if element != nil, issue.auditType == .dynamicType, issue.compactDescription == partlyScalingWords {
        partlyScaling += 1
      }
      let described =
        element.map { "\($0.label), element type \($0.elementType.rawValue), at \($0.frame)" } ?? "no element"
      issues.append(
        "\(issue.compactDescription): \(issue.detailedDescription) (\(described), check \(name(of: issue.auditType)))")
      return true
    }
    return (issues, lostElements, partlyScaling)
  }

  /// The name of an audit's check, such as `contrast`, so a failure or a retry says which check gave the issue. The
  /// named flake "an audit's issue has no element" in `docs/development.md` has come from more than one check.
  private static func name(of type: XCUIAccessibilityAuditType) -> String {
    let names: [(XCUIAccessibilityAuditType, String)] = [
      (.contrast, "contrast"), (.elementDetection, "element detection"), (.hitRegion, "hit region"),
      (.sufficientElementDescription, "element description"), (.dynamicType, "Dynamic Type"),
      (.textClipped, "clipped text"), (.trait, "trait"),
    ]
    let named = names.filter { type.contains($0.0) }.map(\.1)
    return named.isEmpty ? "unknown (\(type.rawValue))" : named.joined(separator: ", ")
  }

  /// Whether a link inside a line of text shows on the screen in part only: some of it is on the window, and some of
  /// it is above the top of the content, under the navigation bar, or below the content's bottom, under the tab bar
  /// or off the screen. A web link row is a link too, but it is an element of its own, which the audit places, so
  /// it doesn't count. Its words end with "opens in browser".
  private static func hasLinkCut(by contentTop: CGFloat, in app: XCUIApplication) -> Bool {
    let window = app.windows.firstMatch.frame
    let bar = app.tabBars.firstMatch
    let bottom = bar.exists ? min(bar.frame.minY, window.maxY) : window.maxY
    return app.links.allElementsBoundByIndex.contains { link in
      guard !link.label.hasSuffix(words("opens in browser")) else { return false }
      let frame = link.frame
      let showsInPart = frame.maxY > window.minY && frame.minY < window.maxY
      return showsInPart && (frame.minY < contentTop - 1 || frame.maxY > bottom + 1)
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

  /// Puts the simulator in the default settings, before a journey launches the app. A run with no helper is in the
  /// simulator's own settings, and stays there.
  ///
  /// `run` puts the simulator back in the default after each setting, but a journey that fails in a setting stops
  /// there, and leaves the simulator in it. The next journey's app then launched in that setting. On 2026-11-24, in
  /// CI run 45292582179 attempt 2, the sign-in journey failed on the help sheet at the largest text size, and the
  /// sign-out journey after it launched at that size: Settings showed only its Signed in block, and the Support
  /// Wishbone rows were below the fold, where the list hadn't made them. So each journey starts in the default. The
  /// helper remembers what it set, so after a journey that ended in the default this makes no `simctl` call.
  static func startInDefaultSettings() async throws {
    guard let helper else { return }
    try await apply(settings[0], helper: helper)
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
    of app: XCUIApplication, _ screen: String, in setting: Setting, after change: Change
  ) async throws -> (screenshot: XCUIScreenshot, pixels: Data) {
    var resends = 0
    while true {
      do {
        return try await settledScreen(
          of: app, screen, in: setting.label, appearance: setting, where: { $0 != change.before },
          before: change.before, unchangedLimit: resends < resendLimit ? unchangedLimit : nil)
      } catch is Unchanged {
        resends += 1
        try await apply(setting, after: change.from, helper: change.helper)
      } catch let error as AuditError where resends > 0 {
        let times = resends == 1 ? "once" : resends == 2 ? "twice" : "\(resends) times"
        throw AuditError("\(error.description) The change was sent again \(times).")
      }
    }
  }

  /// Waits until two screenshots in a row are the same, pass `accept`, and are in the setting's appearance. See
  /// `settledScreen(of:_:in:appearance:where:before:unchangedLimit:)`.
  private static func settledScreen(
    of app: XCUIApplication, _ screen: String, in setting: Setting, where accept: (Data) -> Bool
  ) async throws -> (screenshot: XCUIScreenshot, pixels: Data) {
    try await settledScreen(of: app, screen, in: setting.label, appearance: setting, where: accept)
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
  /// `label` is the words of the setting, for a failure. With no `appearance`, a screenshot in any appearance counts:
  /// the wait is for a still screen only, as in a run with no helper, whose appearance is the simulator's own.
  ///
  /// `before` is the screen before a change. With `unchangedLimit`, it throws `Unchanged` when no screenshot
  /// showed the change for that long: each was exactly `before`, or not in the setting's appearance.
  ///
  /// A request for a screenshot that XCTest timed out (see `Screenshot`) starts the wait again from that point, with
  /// no screenshot before it: the runner stalled, so the time before is not the app's, and the screenshot before the
  /// stall is not one of two in a row. What the screen showed before the stall still counts as shown.
  private static func settledScreen(
    of app: XCUIApplication, _ screen: String, in label: String, appearance: Setting?,
    where accept: (Data) -> Bool, before: Data? = nil, unchangedLimit: Duration? = nil
  ) async throws -> (screenshot: XCUIScreenshot, pixels: Data) {
    var started = ContinuousClock.now
    var deadline = started + settleTimeout
    var last: Data?
    var moved = false
    var inAppearance = false
    var onlyBefore = true
    while true {
      let (screenshot, timeOuts) = try await Screenshot.take(of: app, showing: "\(screen), in \(label)")
      if timeOuts > 0 {
        started = ContinuousClock.now
        deadline = started + settleTimeout
        last = nil
      }
      let pixels = screenshot.pngRepresentation
      let shows = appearance.map { isInAppearance(screenshot, of: $0) } ?? true
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
            inAppearance ? "" : " It never showed \(appearance?.isDark == true ? "dark" : "light") appearance."
          } else if onlyBefore {
            " It showed the screen as it was before the change."
          } else {
            " It never showed the change in \(appearance?.isDark == true ? "dark" : "light") appearance."
          }
        throw AuditError("The screen didn't settle in \(label) within \(settleTimeout).\(unchanged)")
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
