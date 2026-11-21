import GRDB
import WishboneAPI

// The tables of the local copy, and their schema number.
//
// **A change to this file is a change to the copy.** A fitness test holds this file, `Rows.swift`, and the values
// that the rows keep to the schema number.

extension LocalDatabase {
  /// The schema number of the copy's tables. The database keeps the number of the tables that it has.
  ///
  /// **Raise it with every change to the copy:** a change to a table below or to what a row keeps, and a new kind
  /// that the copy starts to hold. A database with another number drops its copy, and the next sync fills the new
  /// tables. Without that, the kept `ETag` could answer a pull with a 304 for a copy that never held the new kind.
  ///
  /// The number is SQLite's `user_version`. The first version of the copy had none, which is 0.
  static let copySchema = 3

  /// One row at most: the `ETag` of the last answer of `GET /versions` that the copy agreed with.
  static let keptETagTable = "keptETag"

  /// The copy's tables: the rows that screens read, and the `ETag` that the pull keeps.
  private static let copyTables = [
    UserRow.databaseTableName, GroupRow.databaseTableName, OccasionRow.databaseTableName,
    MembershipRow.databaseTableName, ListRow.databaseTableName, RecipientRow.databaseTableName,
    ItemRow.databaseTableName, StoreLinkRow.databaseTableName, InvitationRow.databaseTableName, keptETagTable,
  ]

  /// Makes the copy's tables. When the database has the copy of another schema number, it first drops every table
  /// of that copy, with the versions and the kept `ETag`. It touches nothing else in the database.
  ///
  /// Diagnostics: "a migration drops the copy" is captured. Nothing is captured yet: the app has no diagnostics
  /// until `WishboneDiagnostics` holds them.
  static func prepareCopy(in writer: any DatabaseWriter) throws {
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
        // An image summary, as JSON.
        table.column("avatar", .text)
        // The rest of a full user, as JSON. Null for a summary.
        table.column("record", .text)
        table.column("version", .text).notNull()
      }
      try database.create(table: GroupRow.databaseTableName) { table in
        table.primaryKey("id", .text)
        table.column("name", .text).notNull()
        table.column("createdAt", .datetime).notNull()
        table.column("throughGroupID", .text)
        table.column("canEdit", .boolean).notNull()
        table.column("canDelete", .boolean).notNull()
        table.column("canAddUser", .boolean).notNull()
        table.column("canAddGroup", .boolean).notNull()
        table.column("version", .text).notNull()
      }
      try database.create(table: OccasionRow.databaseTableName) { table in
        table.primaryKey("id", .text)
        table.column("kind", .text).notNull()
        table.column("name", .text).notNull()
        // The date rule, as JSON.
        table.column("rule", .text).notNull()
        table.column("userID", .text)
        table.column("isEveryone", .boolean)
        table.column("nextDate", .text)
        table.column("canEdit", .boolean).notNull()
        table.column("canDelete", .boolean).notNull()
        table.column("canAttachGroup", .boolean).notNull()
        table.column("version", .text).notNull()
      }
      try database.create(table: MembershipRow.databaseTableName) { table in
        table.primaryKey {
          table.column("kind", .text)
          table.column("ownerID", .text)
        }
        // The IDs of the members in the server's order, as a JSON list. A list with nothing in it is a membership
        // with no members. A membership that the user can't read has no row.
        table.column("memberIDs", .text).notNull()
        table.column("version", .text).notNull()
      }
      try database.create(table: ListRow.databaseTableName) { table in
        table.primaryKey("id", .text)
        table.column("name", .text).notNull()
        table.column("description", .text)
        table.column("isPrimary", .boolean).notNull()
        // The IDs of the recipients in the server's order, as a JSON list.
        table.column("recipientIDs", .text).notNull()
        table.column("itemCount", .integer).notNull()
        table.column("createdAt", .datetime).notNull()
        table.column("canEdit", .boolean).notNull()
        table.column("canDelete", .boolean).notNull()
        table.column("canInvite", .boolean).notNull()
        table.column("canLeave", .boolean).notNull()
        table.column("version", .text).notNull()
      }
      try database.create(table: RecipientRow.databaseTableName) { table in
        table.primaryKey {
          table.column("listID", .text)
          table.column("userID", .text)
        }
        table.column("createdAt", .datetime).notNull()
        // Hidden, or shown with a value or with none, as JSON.
        table.column("seesListAfterLeaving", .text).notNull()
        table.column("canDelete", .boolean).notNull()
        table.column("version", .text).notNull()
      }
      try database.create(table: ItemRow.databaseTableName) { table in
        table.primaryKey("id", .text)
        table.column("listID", .text).notNull().indexed()
        table.column("title", .text).notNull()
        table.column("notes", .text)
        table.column("priceMinor", .integer)
        table.column("topPriceMinor", .integer)
        table.column("currency", .text)
        table.column("quantity", .integer).notNull()
        table.column("isUnlimited", .boolean).notNull()
        table.column("position", .integer).notNull()
        table.column("addedByID", .text)
        table.column("createdAt", .datetime).notNull()
        // The image summaries, as JSON.
        table.column("images", .text).notNull()
        table.column("primaryImage", .text)
        // The claim state: hidden, or shown with a value or with none, as JSON.
        table.column("stillWanted", .text).notNull()
        table.column("myClaimedQuantity", .text).notNull()
        table.column("canEdit", .boolean).notNull()
        table.column("canDelete", .boolean).notNull()
        table.column("canClaim", .boolean).notNull()
        table.column("canRefreshPrices", .boolean).notNull()
        table.column("version", .text).notNull()
      }
      try database.create(table: StoreLinkRow.databaseTableName) { table in
        table.primaryKey("id", .text)
        table.column("itemID", .text).notNull().indexed()
        table.column("position", .integer).notNull()
        table.column("url", .text).notNull()
        table.column("store", .text).notNull()
        table.column("priceMinor", .integer)
        table.column("currency", .text)
        table.column("capturedAt", .datetime)
        table.column("imageURL", .text)
        table.column("createdAt", .datetime).notNull()
        table.column("canEdit", .boolean).notNull()
        table.column("canDelete", .boolean).notNull()
        table.column("version", .text).notNull()
      }
      try database.create(table: InvitationRow.databaseTableName) { table in
        table.primaryKey("id", .text)
        table.column("listID", .text).notNull()
        table.column("listName", .text).notNull()
        table.column("userID", .text).notNull()
        table.column("invitedByID", .text)
        table.column("createdAt", .datetime).notNull()
        table.column("canAccept", .boolean).notNull()
        table.column("canDelete", .boolean).notNull()
        table.column("version", .text).notNull()
      }
      try database.create(table: keptETagTable) { table in
        table.column("etag", .text).notNull()
      }
      try database.execute(sql: "PRAGMA user_version = \(copySchema)")
    }
  }
}
