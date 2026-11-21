import CryptoKit
import Foundation
import GRDB
import WishboneAPI

/// The local database of one session: the copy of what the session's user can see. See ADR 0005, and "Where the
/// database lives" in `docs/spec.md`.
///
/// Screens read only this database, through the session model. The API only feeds it. The copy's tables can be
/// dropped and rebuilt at any time.
struct LocalDatabase: Sendable {
  let writer: any DatabaseWriter

  /// A database in memory. Nothing is on disk.
  static func inMemory() throws -> LocalDatabase {
    try LocalDatabase(writer: DatabaseQueue())
  }

  /// Opens the database file, and makes it when there is none.
  static func open(at file: URL) throws -> LocalDatabase {
    var configuration = Configuration()
    // Another connection can hold the file for a moment, for example while it closes. The open waits for it.
    configuration.busyMode = .timeout(5)
    return try LocalDatabase(writer: DatabasePool(path: file.path(percentEncoded: false), configuration: configuration))
  }

  private init(writer: any DatabaseWriter) throws {
    self.writer = writer
    try Self.migrator.migrate(writer)
  }

  private static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("the copy: a user, a list, and its items") { database in
      try database.create(table: UserRow.databaseTableName) { table in
        table.primaryKey("id", .text)
        table.column("name", .text).notNull()
        table.column("primaryListID", .text)
      }
      try database.create(table: ListRow.databaseTableName) { table in
        table.primaryKey("id", .text)
        table.column("name", .text).notNull()
      }
      try database.create(table: ItemRow.databaseTableName) { table in
        table.primaryKey("id", .text)
        table.column("listID", .text).notNull().indexed()
        table.column("title", .text).notNull()
        table.column("position", .integer).notNull()
        table.column("version", .text).notNull()
      }
    }
    return migrator
  }

  // MARK: - Where the file goes

  /// The folder of one session's files, under the app's Application Support folder. Its name is made from the
  /// instance address and the user's ID, so each instance and user has a folder of its own, and the name gives
  /// neither away.
  static func folder(of session: Session, under base: URL) -> URL {
    let key = SHA256.hash(data: Data("\(session.instance.text)\n\(session.userID)".utf8))
    let name = key.prefix(16).map { byte in
      let hex = String(byte, radix: 16)
      return hex.count == 1 ? "0\(hex)" : hex
    }.joined()
    return base.appending(path: "Sessions", directoryHint: .isDirectory).appending(
      path: name, directoryHint: .isDirectory)
  }

  /// The database of the session, as the storage says.
  ///
  /// A database file that is not a database any more is removed and made again: it holds only the copy, which the
  /// next sync fills. When the file can't be opened for another reason, or no file can be made, the database is in
  /// memory, so the session still works until the app ends. The file stays as it is.
  ///
  /// Diagnostics: "the local database will not open" is captured, by its code only. Nothing is captured yet: the
  /// app has no diagnostics until `WishboneDiagnostics` holds them.
  static func of(_ session: Session, in storage: SessionStorage) -> LocalDatabase? {
    if case .folder(let base) = storage {
      let folder = folder(of: session, under: base)
      do {
        return try open(in: folder)
      } catch let error as DatabaseError where [.SQLITE_CORRUPT, .SQLITE_NOTADB].contains(error.resultCode) {
        Log.fault(.session, "The local database is damaged. It is made again.", detail: "\(error)")
        try? FileManager.default.removeItem(at: folder)
        if let database = try? open(in: folder) { return database }
      } catch {
        Log.fault(.session, "The local database will not open.", detail: "\(error)")
      }
    }
    do {
      return try inMemory()
    } catch {
      Log.fault(.session, "The local database will not open in memory.", detail: "\(error)")
      return nil
    }
  }

  private static func open(in folder: URL) throws -> LocalDatabase {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // The folder is left out of backups: the copy comes from the instance again. Its files keep iOS's default
    // file protection, so background refresh can sync while the device is locked.
    var folder = folder
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try folder.setResourceValues(values)
    return try open(at: folder.appending(path: "database.sqlite"))
  }

  // MARK: - What the pull writes

  /// Writes what a pull fetched: the session's user, and the items of the user's primary list, in one change.
  /// An item of the list that the pull didn't fetch is gone from the server, so it goes from the copy.
  func save(user: User, primaryListItems items: [Item]) async throws {
    try await writer.write { database in
      try UserRow(id: user.id, name: user.name, primaryListID: user.primaryList?.id).save(database)
      guard let list = user.primaryList else { return }
      try ListRow(id: list.id, name: list.name).save(database)
      let kept = items.map(\.id)
      try ItemRow.filter(Column("listID") == list.id && !kept.contains(Column("id"))).deleteAll(database)
      for item in items {
        let row = ItemRow(
          id: item.id, listID: item.listID, title: item.title, position: item.position, version: item.version)
        try row.save(database)
      }
    }
  }

  // MARK: - What the session model publishes

  /// The session's user, the user's primary list, and its items in the list's order.
  struct Snapshot: Sendable, Equatable {
    var user: UserRow?
    var primaryList: ListRow?
    var primaryListItems: [ItemRow] = []
  }

  /// An observation of the snapshot for the user. It gives a new snapshot after each change to the copy.
  static func snapshots(ofUser id: String) -> ValueObservation<
    ValueReducers.RemoveDuplicates<ValueReducers.Fetch<Snapshot>>
  > {
    ValueObservation.tracking { database in
      var snapshot = Snapshot()
      snapshot.user = try UserRow.fetchOne(database, key: id)
      guard let listID = snapshot.user?.primaryListID else { return snapshot }
      snapshot.primaryList = try ListRow.fetchOne(database, key: listID)
      snapshot.primaryListItems = try ItemRow.filter(Column("listID") == listID)
        .order(Column("position"), Column("id")).fetchAll(database)
      return snapshot
    }.removeDuplicates()
  }
}
