import Foundation
import Testing

/// Only the app registers background app refresh: it permits the one task's identifier, and has the background mode
/// that the task needs. Neither extension has either. See "Where the other pieces live" in `docs/architecture.md`.
@Suite("Background refresh", .timeLimit(.minutes(1)))
struct BackgroundRefreshTests {
  static let identifiers = "BGTaskSchedulerPermittedIdentifiers"
  static let modes = "UIBackgroundModes"

  @Test("The app permits its refresh task and has the fetch mode. Neither extension has either")
  func onlyTheApp() throws {
    // The hosted tests run inside the app, so the main bundle is the app's.
    let app = try #require(Bundle.main.infoDictionary)
    let bundleID = try #require(Bundle.main.bundleIdentifier)
    #expect(app[Self.identifiers] as? [String] == ["\(bundleID).refresh"])
    #expect(app[Self.modes] as? [String] == ["fetch"])

    let plugIns = try #require(Bundle.main.builtInPlugInsURL)
    let extensions = try FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "appex" }
    #expect(
      Set(extensions.map { $0.deletingPathExtension().lastPathComponent }) == ["ShareExtension", "WidgetExtension"])
    for url in extensions {
      let info = try #require(Bundle(url: url)?.infoDictionary, "\(url.lastPathComponent)")
      #expect(info[Self.identifiers] == nil, "\(url.lastPathComponent)")
      #expect(info[Self.modes] == nil, "\(url.lastPathComponent)")
    }
  }
}
