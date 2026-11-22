import Foundation
import WishboneAPI

/// Where a session keeps its reminder settings: a small file in the session's own folder, beside its local database.
/// See "One switch, and the timing" in `docs/spec.md`.
///
/// The settings belong to the session, so they go at sign-out with the session's folder. They are not in the copy's
/// tables, which a change of the copy's schema number drops: the settings are the user's choice, and no sync brings
/// them back.
///
/// A session in memory keeps them in memory only, until the app ends.
struct ReminderSettingsFile: Sendable {
  /// The file. Nil for a session in memory.
  let url: URL?

  /// The file of the session, as the storage says.
  init(of session: Session, in storage: SessionStorage) {
    switch storage {
    case .memory:
      url = nil
    case .folder(let base):
      url = LocalDatabase.folder(of: session, under: base).appending(path: "reminder-settings.json")
    }
  }

  /// The settings in the file. The defaults when there is no file, or none that can be read.
  ///
  /// Diagnostics: never. A file that can't be read is logged, and the defaults hold.
  func read() -> ReminderSettings {
    guard let url else { return ReminderSettings() }
    do {
      return try JSONDecoder().decode(ReminderSettings.self, from: Data(contentsOf: url))
    } catch CocoaError.fileReadNoSuchFile {
      return ReminderSettings()
    } catch {
      Log.notice(.session, "The reminder settings can't be read. The defaults hold.", detail: "\(error)")
      return ReminderSettings()
    }
  }

  /// Saves the settings to the file, whole. It is a file of its own, not the local database.
  ///
  /// Diagnostics: never. A file that can't be written is logged, and the settings hold until the app ends.
  func save(_ settings: ReminderSettings) {
    guard let url else { return }
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(settings).write(to: url, options: .atomic)
    } catch {
      Log.notice(.session, "The reminder settings can't be written.", detail: "\(error)")
    }
  }
}
