import CryptoKit
import Foundation
import GRDB
import WishboneAPI

/// The local database of one session: the copy of what the session's user can see. See ADR 0005, and "Where the
/// database lives" in `docs/spec.md`.
///
/// Screens read only this database, through the session model. The API only feeds it. The copy's tables can be
/// dropped and rebuilt at any time: they have a schema number of their own, apart from anything that the database
/// must keep.
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
    try Self.prepareCopy(in: writer)
  }

  // MARK: - The copy's tables

  /// The schema number of the copy's tables. The database keeps the number of the tables that it has.
  ///
  /// **Raise it with every change to the copy:** a change to a table below, and a new kind that the copy starts to
  /// hold. A database with another number drops its copy, and the next sync fills the new tables. Without that,
  /// the kept `ETag` could answer a pull with a 304 for a copy that never held the new kind.
  ///
  /// The number is SQLite's `user_version`. The first version of the copy had none, which is 0.
  static let copySchema = 1

  /// The copy's tables: the rows that screens read, and the `ETag` that the pull keeps.
  private static let copyTables = [
    UserRow.databaseTableName, ListRow.databaseTableName, ItemRow.databaseTableName, keptETagTable,
  ]

  /// One row at most: the `ETag` of the last answer of `GET /versions` that the copy agreed with.
  private static let keptETagTable = "keptETag"

  /// Makes the copy's tables. When the database has the copy of another schema number, it first drops every table
  /// of that copy, with the versions and the kept `ETag`. It touches nothing else in the database.
  ///
  /// Diagnostics: "a migration drops the copy" is captured. Nothing is captured yet: the app has no diagnostics
  /// until `WishboneDiagnostics` holds them.
  private static func prepareCopy(in writer: any DatabaseWriter) throws {
    try writer.write { database in
      guard try Int.fetchOne(database, sql: "PRAGMA user_version") != copySchema else { return }
      var hadCopy = false
      for table in copyTables where try database.tableExists(table) {
        try database.drop(table: table)
        hadCopy = true
      }
      if hadCopy { Log.fault(.session, "The copy has another schema number. It is dropped.") }

      try database.create(table: UserRow.databaseTableName) { table in
        table.primaryKey("id", .text)
        table.column("name", .text).notNull()
        table.column("primaryListID", .text)
        table.column("timezone", .text)
        table.column("version", .text).notNull()
      }
      try database.create(table: ListRow.databaseTableName) { table in
        table.primaryKey("id", .text)
        table.column("name", .text).notNull()
        table.column("version", .text).notNull()
      }
      try database.create(table: ItemRow.databaseTableName) { table in
        table.primaryKey("id", .text)
        table.column("listID", .text).notNull().indexed()
        table.column("title", .text).notNull()
        table.column("position", .integer).notNull()
        table.column("version", .text).notNull()
      }
      try database.create(table: keptETagTable) { table in
        table.column("etag", .text).notNull()
      }
      try database.execute(sql: "PRAGMA user_version = \(copySchema)")
    }
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

  // MARK: - What the pull reads

  /// The `ETag` of the last answer of `GET /versions` that the copy agreed with. Nil when the copy agrees with
  /// none: it is new, or it has changed since.
  func keptETag() async throws -> String? {
    try await writer.read { database in
      try String.fetchOne(database, sql: "SELECT etag FROM \(Self.keptETagTable)")
    }
  }

  /// The user's row in the copy.
  func user(_ id: String) async throws -> UserRow? {
    try await writer.read { database in try UserRow.fetchOne(database, key: id) }
  }

  /// The version of each list in the copy, by the list's ID.
  func listVersions() async throws -> [String: String] {
    try await versions(in: ListRow.databaseTableName)
  }

  /// The version of each item in the copy, by the item's ID.
  func itemVersions() async throws -> [String: String] {
    try await versions(in: ItemRow.databaseTableName)
  }

  private func versions(in table: String) async throws -> [String: String] {
    try await writer.read { database in
      var versions: [String: String] = [:]
      for row in try Row.fetchAll(database, sql: "SELECT id, version FROM \(table)") {
        versions[row["id"]] = row["version"]
      }
      return versions
    }
  }

  // MARK: - What the pull writes

  /// Every change to the copy goes through here. A changed copy no longer agrees with the answer of
  /// `GET /versions` whose `ETag` it kept, so the kept `ETag` goes in the same change. Otherwise a pull that stops
  /// in the middle could leave the copy half changed, and a later 304 would say that it is current.
  private func change<Result: Sendable>(_ updates: @escaping @Sendable (Database) throws -> Result) async throws
    -> Result
  {
    try await writer.write { database in
      try database.execute(sql: "DELETE FROM \(Self.keptETagTable)")
      return try updates(database)
    }
  }

  /// Keeps the `ETag` of an answer of `GET /versions` that the copy agrees with now. Nil keeps none.
  func keep(etag: String?) async throws {
    try await change { database in
      guard let etag else { return }
      try database.execute(sql: "INSERT INTO \(Self.keptETagTable) (etag) VALUES (?)", arguments: [etag])
    }
  }

  /// Saves a user, with the version that the user's own answer carried.
  @discardableResult
  func save(_ user: Versioned<User>) async throws -> UserRow {
    let row = UserRow(
      id: user.resource.id, name: user.resource.name, primaryListID: user.resource.primaryList?.id,
      timezone: user.resource.timezone, version: user.version)
    try await change { database in try row.save(database) }
    return row
  }

  /// Saves a list, with the version that the list's own answer carried.
  func save(_ list: Versioned<ListResource>) async throws {
    let row = ListRow(id: list.resource.id, name: list.resource.name, version: list.version)
    try await change { database in try row.save(database) }
  }

  /// Saves the items, each with the version that its own answer carried, and removes the items with the IDs, in
  /// one change.
  func save(_ items: [Versioned<Item>], removingItems gone: [String] = []) async throws {
    let rows = items.map { item in
      ItemRow(
        id: item.resource.id, listID: item.resource.listID, title: item.resource.title,
        position: item.resource.position, version: item.version)
    }
    try await change { database in
      try ItemRow.deleteAll(database, keys: gone)
      for row in rows {
        try row.save(database)
      }
    }
  }

  /// Removes the user from the copy.
  func removeUser(_ id: String) async throws {
    try await change { database in _ = try UserRow.deleteOne(database, key: id) }
  }

  /// Removes the lists from the copy.
  func removeLists(_ ids: [String]) async throws {
    try await change { database in _ = try ListRow.deleteAll(database, keys: ids) }
  }

  /// Removes the items from the copy.
  func removeItems(_ ids: [String]) async throws {
    try await save([], removingItems: ids)
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
