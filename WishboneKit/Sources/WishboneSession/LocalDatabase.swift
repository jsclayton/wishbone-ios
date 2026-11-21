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

  /// Removes every session's files under the storage, as a sign-out does. A device holds one session at most, so
  /// this also removes what an earlier session could have left. The database must be closed first.
  static func removeAll(in storage: SessionStorage) {
    guard case .folder(let base) = storage else { return }
    let sessions = base.appending(path: "Sessions", directoryHint: .isDirectory)
    do {
      try FileManager.default.removeItem(at: sessions)
    } catch CocoaError.fileNoSuchFile {
      // Nothing to remove.
    } catch {
      Log.fault(.session, "The local database can't be removed.", detail: "\(error)")
    }
  }

  /// Closes the database. Any later use of it throws.
  func close() {
    do {
      if let pool = writer as? DatabasePool {
        try pool.close()
      } else if let queue = writer as? DatabaseQueue {
        try queue.close()
      }
    } catch {
      Log.fault(.session, "The local database can't be closed.", detail: "\(error)")
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

  /// For each of the users, a body of the copy that contains their summary. A user whom no body of the copy names
  /// is not in the answer.
  func bodiesNaming(_ ids: Set<String>) async throws -> [String: Pull.Body] {
    try await writer.read { database in
      var naming: [String: Pull.Body] = [:]
      func named(_ id: String?, by body: Pull.Body) {
        guard let id, ids.contains(id), naming[id] == nil else { return }
        naming[id] = body
      }
      for row in try UserRow.order(Column("id")).fetchAll(database) {
        guard let record = row.record else { continue }
        for id in record.parentIDs + record.childIDs { named(id, by: .user(row.id)) }
      }
      for row in try OccasionRow.order(Column("id")).fetchAll(database) {
        named(row.userID, by: .occasion(row.id))
      }
      for row in try ListRow.order(Column("id")).fetchAll(database) {
        for id in row.recipientIDs { named(id, by: .list(row.id)) }
      }
      for row in try RecipientRow.order(Column("listID"), Column("userID")).fetchAll(database) {
        named(row.userID, by: .recipients(ofList: row.listID))
      }
      for row in try ItemRow.order(Column("id")).fetchAll(database) {
        named(row.addedByID, by: .item(row.id))
      }
      for row in try InvitationRow.order(Column("id")).fetchAll(database) {
        named(row.userID, by: .invitation(row.id))
        named(row.invitedByID, by: .invitation(row.id))
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

  /// The version of each store link in the copy, by the store link's ID.
  func storeLinkVersions() async throws -> [String: String] {
    try await versions(of: StoreLinkRow.self)
  }

  /// The version of each invitation in the copy, by the invitation's ID.
  func invitationVersions() async throws -> [String: String] {
    try await versions(of: InvitationRow.self)
  }

  /// The version of each recipient row in the copy, by its list, and then by its user.
  func recipientVersions() async throws -> [String: [String: String]] {
    try await writer.read { database in
      var versions: [String: [String: String]] = [:]
      for row in try RecipientRow.fetchAll(database) {
        versions[row.listID, default: [:]][row.userID] = row.version
      }
      return versions
    }
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

  /// Saves the lists, each with the version that its own answer carried, and removes the lists with the IDs, in
  /// one change. A list's recipients are summaries, saved as the summaries of a user's body are. A removed list
  /// takes its items, their store links, and its recipient rows with it.
  func save(
    _ lists: [Versioned<ListResource>],
    summaries: [String: String] = [:],
    removingLists gone: [String] = []
  ) async throws {
    let rows = lists.map { ListRow($0) }
    let inBodies = Self.summaryRows(of: lists.flatMap(\.resource.recipients), named: summaries)
    try await change { database in
      try Self.removeLists(gone, in: database)
      for row in inBodies {
        try row.save(database)
      }
      for row in rows {
        try row.save(database)
      }
    }
  }

  /// Saves rows of a list's recipients, each with the version that its row carried, and removes the rows of the
  /// users with the IDs, in one change. Each recipient is a summary, saved as the summaries of a user's body are.
  func save(
    _ recipients: [Versioned<Recipient>],
    ofList listID: String,
    summaries: [String: String] = [:],
    removingRecipients gone: [String] = []
  ) async throws {
    let rows = recipients.map { RecipientRow($0, ofList: listID) }
    let inBodies = Self.summaryRows(of: recipients.map(\.resource.user), named: summaries)
    try await change { database in
      for userID in gone {
        try RecipientRow.deleteOne(database, key: ["listID": listID, "userID": userID])
      }
      for row in inBodies {
        try row.save(database)
      }
      for row in rows {
        try row.save(database)
      }
    }
  }

  /// Saves the items, each with the version that its own answer carried, and removes the items with the IDs, in
  /// one change.
  ///
  /// An item's body has its store links, in the server's order for the session's user. They take the place of the
  /// item's store links in the copy, each with the version that `GET /versions` named for it in `storeLinks`: no
  /// body carries one. A store link that it doesn't name has no version, so the next pull compares it again. The
  /// user who added the item is a summary, saved as the summaries of a user's body are. A removed item takes its
  /// store links with it.
  func save(
    _ items: [Versioned<Item>],
    storeLinks versions: [String: String] = [:],
    summaries: [String: String] = [:],
    removingItems gone: [String] = []
  ) async throws {
    let rows = items.map { ItemRow($0) }
    let links = items.flatMap { item in
      item.resource.storeLinks.enumerated().map { position, link in
        StoreLinkRow(link, ofItem: item.resource.id, at: position, version: versions[link.id] ?? "")
      }
    }
    let inBodies = Self.summaryRows(of: items.compactMap(\.resource.addedBy), named: summaries)
    try await change { database in
      try Self.removeItems(gone + items.map(\.resource.id), in: database)
      for row in inBodies {
        try row.save(database)
      }
      for row in rows {
        try row.save(database)
      }
      for row in links {
        try row.save(database)
      }
    }
  }

  /// Saves the invitations, each with the version that its own answer carried, and removes the invitations with
  /// the IDs, in one change. An invitation's users are summaries, saved as the summaries of a user's body are.
  func save(
    _ invitations: [Versioned<Invitation>],
    summaries: [String: String] = [:],
    removingInvitations gone: [String] = []
  ) async throws {
    let rows = invitations.map { InvitationRow($0) }
    let users = invitations.flatMap { [$0.resource.user] + ($0.resource.invitedBy.map { [$0] } ?? []) }
    let inBodies = Self.summaryRows(of: users, named: summaries)
    try await change { database in
      try InvitationRow.deleteAll(database, keys: gone)
      for row in inBodies {
        try row.save(database)
      }
      for row in rows {
        try row.save(database)
      }
    }
  }

  /// Removes every row that the answer of `GET /versions` doesn't name, in one change: what was deleted, moved
  /// out of view, or hidden. A user who is no longer named in full, and is named as a summary, becomes a summary
  /// with the version that the answer named for it: the name and the avatar stay, and the rest goes.
  func removeWhatIsAbsent(from named: Pull.Named) async throws {
    try await change { database in
      let users = try Row.fetchAll(
        database, sql: "SELECT id, record IS NULL AS isSummary FROM \(Self.quoted(UserRow.self))")
      for row in users {
        let id: String = row["id"]
        let isSummary: Bool = row["isSummary"]
        if named.users[id] != nil { continue }
        if let version = named.summaries[id] {
          guard !isSummary else { continue }
          try database.execute(
            sql: "UPDATE \(Self.quoted(UserRow.self)) SET record = NULL, version = ? WHERE id = ?",
            arguments: [version, id])
        } else {
          _ = try UserRow.deleteOne(database, key: id)
        }
      }
      func absent<Record: TableRecord>(_ record: Record.Type, from named: [String: String]) throws -> [String] {
        try String.fetchAll(database, sql: "SELECT id FROM \(Self.quoted(record))").filter { named[$0] == nil }
      }
      try GroupRow.deleteAll(database, keys: try absent(GroupRow.self, from: named.groups))
      try OccasionRow.deleteAll(database, keys: try absent(OccasionRow.self, from: named.occasions))
      try InvitationRow.deleteAll(database, keys: try absent(InvitationRow.self, from: named.invitations))
      try Self.removeLists(try absent(ListRow.self, from: named.lists), in: database)
      try Self.removeItems(try absent(ItemRow.self, from: named.itemsByID), in: database)
      try StoreLinkRow.deleteAll(database, keys: try absent(StoreLinkRow.self, from: named.storeLinks))
      for row in try MembershipRow.fetchAll(database) where named.memberships[row.key] == nil {
        try row.delete(database)
      }
      for row in try RecipientRow.fetchAll(database) where named.recipients[row.listID]?[row.userID] == nil {
        try row.delete(database)
      }
    }
  }

  /// Removes the list, with its items, their store links, and its recipient rows: the list went between two
  /// requests.
  func removeList(_ id: String) async throws {
    try await change { database in try Self.removeLists([id], in: database) }
  }

  /// Removes the summaries of the users with the IDs. A user held in full stays.
  func removeSummaries(_ ids: [String]) async throws {
    try await change { database in
      for id in ids {
        try database.execute(
          sql: "DELETE FROM \(Self.quoted(UserRow.self)) WHERE id = ? AND record IS NULL", arguments: [id])
      }
    }
  }

  /// Removes the lists, with their items, the items' store links, and the lists' recipient rows.
  private static func removeLists(_ ids: [String], in database: Database) throws {
    guard !ids.isEmpty else { return }
    try ListRow.deleteAll(database, keys: ids)
    try RecipientRow.filter(ids.contains(Column("listID"))).deleteAll(database)
    let items = try String.fetchAll(database, ItemRow.select(Column("id")).filter(ids.contains(Column("listID"))))
    try removeItems(items, in: database)
  }

  /// Removes the items, with their store links.
  private static func removeItems(_ ids: [String], in database: Database) throws {
    guard !ids.isEmpty else { return }
    try ItemRow.deleteAll(database, keys: ids)
    try StoreLinkRow.filter(ids.contains(Column("itemID"))).deleteAll(database)
  }

  // MARK: - What the session model publishes

  /// What the session model publishes from the copy.
  struct Snapshot: Sendable, Equatable {
    /// The session's user, when the copy holds them in full.
    var user: UserRow?
    var primaryList: ListRow?

    /// The items on the primary list, in the list's order.
    var primaryListItems: [ItemRow] = []

    /// Every list of the copy, by name.
    var lists: [ListRow] = []

    /// The items of each list of the copy, by the list's ID, in the list's order. A list that is not in the copy
    /// has none here: the pull saves a list's items before the list, in another write, so the list and its items
    /// show in the same change.
    var items: [String: [ItemRow]] = [:]

    /// The store links of each item, by the item's ID, in the order of the item's body.
    var storeLinks: [String: [StoreLinkRow]] = [:]

    /// The recipient rows of each list of the copy, by the list's ID, in the order of the list's recipients. A row
    /// that the list doesn't name yet comes last.
    var recipients: [String: [RecipientRow]] = [:]

    /// Every pending invitation of the copy, the oldest first.
    var invitations: [InvitationRow] = []

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
      snapshot.lists = try ListRow.order(Column("name"), Column("id")).fetchAll(database)
      let listIDs = Set(snapshot.lists.map(\.id))
      for item in try ItemRow.order(Column("listID"), Column("position"), Column("id")).fetchAll(database)
      where listIDs.contains(item.listID) {
        snapshot.items[item.listID, default: []].append(item)
      }
      for link in try StoreLinkRow.order(Column("itemID"), Column("position"), Column("id")).fetchAll(database) {
        snapshot.storeLinks[link.itemID, default: []].append(link)
      }
      // The rows of a list go in the order of the list's own recipients: the order they became recipients, as the
      // server gives it. Two can have the same time.
      var rows: [String: [RecipientRow]] = [:]
      for row in try RecipientRow.order(Column("createdAt"), Column("userID")).fetchAll(database) {
        rows[row.listID, default: []].append(row)
      }
      for list in snapshot.lists {
        guard let unordered = rows[list.id] else { continue }
        let named = list.recipientIDs.compactMap { id in unordered.first { $0.userID == id } }
        snapshot.recipients[list.id] = named + unordered.filter { !list.recipientIDs.contains($0.userID) }
      }
      snapshot.invitations = try InvitationRow.order(Column("createdAt"), Column("id")).fetchAll(database)
      snapshot.users = try UserRow.order(Column("name"), Column("id")).fetchAll(database)
      snapshot.groups = try GroupRow.order(Column("name"), Column("id")).fetchAll(database)
      snapshot.occasions = try OccasionRow.order(
        Column("nextDate").ascNullsLast, Column("name"), Column("id")
      ).fetchAll(database)
      snapshot.memberships = try MembershipRow.order(Column("kind"), Column("ownerID")).fetchAll(database)
      snapshot.user = snapshot.users.first { $0.id == id && !$0.isSummary }
      guard let listID = snapshot.user?.record?.primaryListID else { return snapshot }
      snapshot.primaryList = snapshot.lists.first { $0.id == listID }
      snapshot.primaryListItems = snapshot.items[listID] ?? []
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

extension ListRow {
  init(_ list: Versioned<ListResource>) {
    let resource = list.resource
    self.init(
      id: resource.id, name: resource.name, description: resource.description, isPrimary: resource.isPrimary,
      recipientIDs: resource.recipients.map(\.id), itemCount: resource.itemCount, createdAt: resource.createdAt,
      canEdit: resource.canEdit, canDelete: resource.canDelete, canInvite: resource.canInvite,
      canLeave: resource.canLeave, version: list.version)
  }
}

extension RecipientRow {
  init(_ recipient: Versioned<Recipient>, ofList listID: String) {
    let resource = recipient.resource
    self.init(
      listID: listID, userID: resource.user.id, createdAt: resource.createdAt,
      seesListAfterLeaving: resource.seesListAfterLeaving, canDelete: resource.canDelete, version: recipient.version)
  }
}

extension ItemRow {
  init(_ item: Versioned<Item>) {
    let resource = item.resource
    self.init(
      id: resource.id, listID: resource.listID, title: resource.title, notes: resource.notes,
      priceMinor: resource.priceMinor, topPriceMinor: resource.topPriceMinor, currency: resource.currency,
      quantity: resource.quantity, isUnlimited: resource.isUnlimited, position: resource.position,
      addedByID: resource.addedBy?.id, createdAt: resource.createdAt, images: resource.images,
      primaryImage: resource.primaryImage, stillWanted: resource.stillWanted,
      myClaimedQuantity: resource.myClaimedQuantity, canEdit: resource.canEdit, canDelete: resource.canDelete,
      canClaim: resource.canClaim, canRefreshPrices: resource.canRefreshPrices, version: item.version)
  }
}

extension StoreLinkRow {
  init(_ link: StoreLink, ofItem itemID: String, at position: Int, version: String) {
    self.init(
      id: link.id, itemID: itemID, position: position, url: link.url, store: link.store,
      priceMinor: link.priceMinor, currency: link.currency, capturedAt: link.capturedAt, imageURL: link.imageURL,
      createdAt: link.createdAt, canEdit: link.canEdit, canDelete: link.canDelete, version: version)
  }
}

extension InvitationRow {
  init(_ invitation: Versioned<Invitation>) {
    let resource = invitation.resource
    self.init(
      id: resource.id, listID: resource.list.id, listName: resource.list.name, userID: resource.user.id,
      invitedByID: resource.invitedBy?.id, createdAt: resource.createdAt, canAccept: resource.canAccept,
      canDelete: resource.canDelete, version: invitation.version)
  }
}
