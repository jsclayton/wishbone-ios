import Foundation
import SQLite3

/// A session's database file on disk, as a test finds it after the app has ended. A test reads and changes the
/// file itself, as another version of the app could have left it, and never through the app's own code.
struct DatabaseFile {
  /// The folder of the one session under the device's storage folder.
  let folder: URL

  var url: URL {
    folder.appending(path: "database.sqlite")
  }

  struct NotOneSession: Error {}

  struct Refused: Error, CustomStringConvertible {
    let description: String
  }

  /// The database file of the one session that the device has under its storage folder.
  init(under storage: URL) throws {
    let sessions = try FileManager.default.contentsOfDirectory(
      at: storage.appending(path: "Sessions"), includingPropertiesForKeys: nil)
    guard sessions.count == 1, let folder = sessions.first else { throw NotOneSession() }
    self.folder = folder
  }

  /// What the database holds on disk: the bytes of the file and of its write-ahead log. Any write to the database
  /// changes them. The shared-memory file is left out, because a read changes it too.
  var contents: [String: Data] {
    get throws {
      var contents: [String: Data] = [:]
      for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      where !file.lastPathComponent.hasSuffix("-shm") {
        contents[file.lastPathComponent] = try Data(contentsOf: file)
      }
      return contents
    }
  }

  /// Runs SQL on the file, through SQLite itself.
  func execute(_ sql: String) throws {
    var connection: OpaquePointer?
    defer { sqlite3_close(connection) }
    guard sqlite3_open_v2(url.path(percentEncoded: false), &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
      throw Refused(description: "The database file will not open.")
    }
    // The app's own connection can still hold the file for a moment while it closes.
    sqlite3_busy_timeout(connection, 5000)
    guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
      throw Refused(description: String(cString: sqlite3_errmsg(connection)))
    }
  }
}
