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

  // MARK: - Where the file goes

  /// The folder of one session's files, under the app's Application Support folder. Its name is made from the
  /// instance address and the user's ID, so each instance and user has a folder of its own, and the name gives
  /// neither away.
  static func folder(of session: Session, under base: URL) -> URL {
    base.appending(path: "Sessions", directoryHint: .isDirectory).appending(
      path: session.opaqueName, directoryHint: .isDirectory)
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

  /// The user's row in the copy, when the copy holds the user in full.
  func user(_ id: String) async throws -> UserRow? {
    try await writer.read { database in
      try UserRow.fetchOne(database, key: id).flatMap { $0.isSummary ? nil : $0 }
    }
  }

  /// The version of each user in the copy, by the user's ID: the users held in full, and the summaries.
  func userVersions() async throws -> (full: [String: String], summaries: [String: String]) {
    try await writer.read { database in
      var full: [String: String] = [:]
      var summaries: [String: String] = [:]
      let rows = try Row.fetchAll(
        database, sql: "SELECT id, version, record IS NULL AS isSummary FROM \(Self.quoted(UserRow.self))")
      for row in rows {
        if row["isSummary"] { summaries[row["id"]] = row["version"] } else { full[row["id"]] = row["version"] }
      }
      return (full, summaries)
    }
  }

  /// For each of the users, a user of the copy whose record names them as a parent or a child: a body that
  /// contains the user's summary. A user that no record names is not in the answer.
  func usersNaming(_ ids: Set<String>) async throws -> [String: String] {
    try await writer.read { database in
      var naming: [String: String] = [:]
      for row in try UserRow.order(Column("id")).fetchAll(database) {
        guard let record = row.record else { continue }
        for id in record.parentIDs + record.childIDs where ids.contains(id) && naming[id] == nil {
          naming[id] = row.id
        }
      }
      return naming
    }
  }

  /// The version of each group in the copy, by the group's ID.
  func groupVersions() async throws -> [String: String] {
    try await versions(of: GroupRow.self)
  }

  /// The version of each occasion in the copy, by the occasion's ID.
  func occasionVersions() async throws -> [String: String] {
    try await versions(of: OccasionRow.self)
  }

  /// The occasions of the copy that are one user's own, by the occasion's ID, each with its user: the birthdays
  /// and the custom occasions.
  func usersOfOwnOccasions() async throws -> [String: String] {
    try await writer.read { database in
      var users: [String: String] = [:]
      for occasion in try OccasionRow.fetchAll(database) {
        guard [.birthday, .custom].contains(occasion.kind), let userID = occasion.userID else { continue }
        users[occasion.id] = userID
      }
      return users
    }
  }

  /// The version of each membership in the copy.
  func membershipVersions() async throws -> [MembershipRow.Key: String] {
    try await writer.read { database in
      var versions: [MembershipRow.Key: String] = [:]
      for row in try MembershipRow.fetchAll(database) {
        versions[row.key] = row.version
      }
      return versions
    }
  }

  /// The version of each list in the copy, by the list's ID.
  func listVersions() async throws -> [String: String] {
    try await versions(of: ListRow.self)
  }

  /// The version of each item in the copy, by the item's ID.
  func itemVersions() async throws -> [String: String] {
    try await versions(of: ItemRow.self)
  }

  private func versions<Record: TableRecord>(of record: Record.Type) async throws -> [String: String] {
    try await writer.read { database in
      var versions: [String: String] = [:]
      for row in try Row.fetchAll(database, sql: "SELECT id, version FROM \(Self.quoted(record))") {
        versions[row["id"]] = row["version"]
      }
      return versions
    }
  }

  /// The record's table, as SQL names it. One table has the name of a word of SQL: `group`.
  private static func quoted<Record: TableRecord>(_ record: Record.Type) -> String {
    record.databaseTableName.quotedDatabaseIdentifier
  }

  // MARK: - What the pull writes

  /// Every change to the copy goes through here. A changed copy no longer agrees with the answer of
  /// `GET /versions` whose `ETag` it kept, so the kept `ETag` goes in the same change. Otherwise a pull that stops
  /// in the middle could leave the copy half changed, and a later 304 would say that it is current.
  ///
  /// A fitness test holds this: nothing else in the module writes to the database.
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

  /// Saves the users in full, each with the version that the user's own answer carried, and removes the users
  /// with the IDs, in one change.
  ///
  /// A user's body has the summaries of the user's parents and children. `summaries` gives the version that
  /// `GET /versions` named for each user whom the session's user gets only as a summary. Each of those in a body
  /// is saved as a summary, with that version, in the same change. A summary in a body is of a user that the body
  /// is as new as, so it takes the place of an older row of that user, also of one in full: the name and the
  /// avatar stay, and the rest goes.
  func save(
    _ users: [Versioned<User>],
    summaries: [String: String] = [:],
    removingUsers gone: [String] = []
  ) async throws {
    let rows = users.map { UserRow($0) }
    let inBodies = Self.summaryRows(of: users.flatMap { $0.resource.parents + $0.resource.children }, named: summaries)
    try await change { database in
      try UserRow.deleteAll(database, keys: gone)
      for row in inBodies + rows {
        try row.save(database)
      }
    }
  }

  /// The rows of the summaries that `GET /versions` named, each with the version that it named.
  private static func summaryRows(of summaries: [UserSummary], named versions: [String: String]) -> [UserRow] {
    summaries.compactMap { summary in
      versions[summary.id].map { version in
        UserRow(id: summary.id, name: summary.name, avatar: summary.avatar, record: nil, version: version)
      }
    }
  }

  /// Makes each of the users a summary, with the version that `GET /versions` named for the summary: the name and
  /// the avatar stay, and the rest of the record goes. It also removes the users with the IDs, in the same change.
  func keepAsSummaries(_ users: [String: String], removingUsers gone: [String]) async throws {
    try await change { database in
      try UserRow.deleteAll(database, keys: gone)
      for (id, version) in users {
        try database.execute(
          sql: "UPDATE \(Self.quoted(UserRow.self)) SET record = NULL, version = ? WHERE id = ?",
          arguments: [version, id])
      }
    }
  }

  /// Saves the groups, each with the version that its own answer carried, and removes the groups with the IDs, in
  /// one change.
  func save(_ groups: [Versioned<Group>], removingGroups gone: [String] = []) async throws {
    let rows = groups.map { GroupRow($0) }
    try await change { database in
      try GroupRow.deleteAll(database, keys: gone)
      for row in rows {
        try row.save(database)
      }
    }
  }

  /// Saves the occasions, each with the version that its own answer carried, and removes the occasions with the
  /// IDs, in one change. The summary of an occasion's user is saved as the summaries of a user's body are.
  func save(
    _ occasions: [Versioned<Occasion>],
    summaries: [String: String] = [:],
    removingOccasions gone: [String] = []
  ) async throws {
    let rows = occasions.map { OccasionRow($0) }
    let inBodies = Self.summaryRows(of: occasions.compactMap(\.resource.user), named: summaries)
    try await change { database in
      try OccasionRow.deleteAll(database, keys: gone)
      for row in inBodies {
        try row.save(database)
      }
      for row in rows {
        try row.save(database)
      }
    }
  }

  /// Saves the memberships, and removes the memberships with the keys, in one change.
  func save(_ memberships: [MembershipRow], removingMemberships gone: [MembershipRow.Key] = []) async throws {
    try await change { database in
      for key in gone {
        try MembershipRow.deleteOne(database, key: ["kind": key.kind.rawValue, "ownerID": key.ownerID])
      }
      for row in memberships {
        try row.save(database)
      }
    }
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

  /// Removes the lists from the copy.
  func removeLists(_ ids: [String]) async throws {
    try await change { database in _ = try ListRow.deleteAll(database, keys: ids) }
  }

  /// Removes the items from the copy.
  func removeItems(_ ids: [String]) async throws {
    try await save([Versioned<Item>](), removingItems: ids)
  }

  // MARK: - What the session model publishes

  /// What the session model publishes from the copy.
  struct Snapshot: Sendable, Equatable {
    /// The session's user, when the copy holds them in full.
    var user: UserRow?
    var primaryList: ListRow?

    /// The items on the primary list, in the list's order.
    var primaryListItems: [ItemRow] = []

    /// Every list of the copy, by ID.
    var lists: [String: ListRow] = [:]

    /// Every user of the copy, in full and as a summary, by name.
    var users: [UserRow] = []

    /// Every group of the copy, by name.
    var groups: [GroupRow] = []

    /// Every occasion of the copy, the soonest first, and one with no date left last.
    var occasions: [OccasionRow] = []
    var memberships: [MembershipRow] = []
  }

  /// An observation of the snapshot for the user. It gives a new snapshot after each change to the copy.
  static func snapshots(ofUser id: String) -> ValueObservation<
    ValueReducers.RemoveDuplicates<ValueReducers.Fetch<Snapshot>>
  > {
    ValueObservation.tracking { database in
      var snapshot = Snapshot()
      for list in try ListRow.fetchAll(database) { snapshot.lists[list.id] = list }
      snapshot.users = try UserRow.order(Column("name"), Column("id")).fetchAll(database)
      snapshot.groups = try GroupRow.order(Column("name"), Column("id")).fetchAll(database)
      snapshot.occasions = try OccasionRow.order(
        Column("nextDate").ascNullsLast, Column("name"), Column("id")
      ).fetchAll(database)
      snapshot.memberships = try MembershipRow.order(Column("kind"), Column("ownerID")).fetchAll(database)
      snapshot.user = snapshot.users.first { $0.id == id && !$0.isSummary }
      // The pull saves the items before their list, in another write. Items whose list is not in the copy yet
      // are not published, so the list and its items show in the same change.
      guard let listID = snapshot.user?.record?.primaryListID,
        let list = try ListRow.fetchOne(database, key: listID)
      else { return snapshot }
      snapshot.primaryList = list
      snapshot.primaryListItems = try ItemRow.filter(Column("listID") == listID)
        .order(Column("position"), Column("id")).fetchAll(database)
      return snapshot
    }.removeDuplicates()
  }
}

extension Session {
  /// A name for the session's instance and user that gives neither away. The folder of the session's files has
  /// this name, and a window's saved place names its session by it.
  public var opaqueName: String {
    let key = SHA256.hash(data: Data("\(instance.text)\n\(userID)".utf8))
    return key.prefix(16).map { byte in
      let hex = String(byte, radix: 16)
      return hex.count == 1 ? "0\(hex)" : hex
    }.joined()
  }
}

// MARK: - A row from the API's model

extension UserRow {
  /// The row of a user in full.
  init(_ user: Versioned<User>) {
    let resource = user.resource
    self.init(
      id: resource.id, name: resource.name, avatar: resource.avatar,
      record: Record(
        lastName: resource.lastName, birthday: resource.birthday, goodToKnow: resource.goodToKnow,
        isAdmin: resource.isAdmin, parentIDs: resource.parents.map(\.id), childIDs: resource.children.map(\.id),
        primaryListID: resource.primaryList?.id, timezone: resource.timezone,
        profileConfirmedAt: resource.profileConfirmedAt, deactivatedAt: resource.deactivatedAt,
        createdAt: resource.createdAt, canEdit: resource.canEdit, canEditParents: resource.canEditParents,
        canMakeLoginLink: resource.canMakeLoginLink, canManageSessions: resource.canManageSessions,
        canDeactivate: resource.canDeactivate, canReactivate: resource.canReactivate,
        canConfirmProfile: resource.canConfirmProfile, canAddOccasion: resource.canAddOccasion),
      version: user.version)
  }
}

extension GroupRow {
  init(_ group: Versioned<Group>) {
    let resource = group.resource
    self.init(
      id: resource.id, name: resource.name, createdAt: resource.createdAt, throughGroupID: resource.through?.id,
      canEdit: resource.canEdit, canDelete: resource.canDelete, canAddUser: resource.canAddUser,
      canAddGroup: resource.canAddGroup, version: group.version)
  }
}

extension OccasionRow {
  init(_ occasion: Versioned<Occasion>) {
    let resource = occasion.resource
    self.init(
      id: resource.id, kind: resource.kind, name: resource.name, rule: resource.rule, userID: resource.user?.id,
      isEveryone: resource.isEveryone, nextDate: resource.nextDate, canEdit: resource.canEdit,
      canDelete: resource.canDelete, canAttachGroup: resource.canAttachGroup, version: occasion.version)
  }
}

extension MembershipRow {
  /// What names one membership: its kind, and its group or occasion.
  struct Key: Hashable, Sendable {
    let kind: Kind
    let ownerID: String
  }

  var key: Key {
    Key(kind: kind, ownerID: ownerID)
  }
}
