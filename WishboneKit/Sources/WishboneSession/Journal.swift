import Foundation
import GRDB
import WishboneAPI

// The journal of unsent changes, in the session's own database, beside the copy. See ADR 0006, and "Unsent
// changes" in `docs/spec.md`.
//
// **The journal is not the copy.** The copy's tables can be dropped and made again at any time: they have a schema
// number of their own (see `CopySchema.swift`). The journal's tables never are. They have their own migrator, which
// never erases the database, so an unsent change carries through every migration of the copy. Its tables are
// never in the copy's list of tables.
//
// **A change shows at once, over the pulled rows.** The copy keeps the server's rows as the pull writes them. The
// snapshot that the session model publishes reads the journal with them, and applies each unsent change over its
// row, in order. So a change shows in every window as soon as the journal holds it, and a pull that writes the row
// again doesn't undo it. When the server accepts the change, its answer goes into the copy and the change leaves
// the journal, in one write: from then on, the server is the authority again. When the server refuses it, it leaves
// the journal, and the row is the server's again: the change is rolled back in every window.
//
// **A change refers to things by the server's ID,** never by a local row ID.
//
// Nothing here goes into the shared container.

/// An unsent change: a change that the app made, and that the server has not accepted yet. See "Unsent change" in
/// `GLOSSARY.md`.
public struct UnsentChange: Sendable, Equatable, Identifiable {
  /// The change's ID in the journal. The journal sends its changes in the order of their IDs.
  public let id: Int64

  /// What the change does.
  public let action: Action

  /// The title of what it changes, as it was when the change was made: what a late refusal names.
  public let title: String

  /// The change's own `Idempotency-Key`. Each send of the change has the same one, so a resend after a lost answer
  /// is the same write.
  let key: String

  /// What an unsent change does. Each is an intent, which the server decides against its own state.
  public enum Action: Sendable, Equatable {
    /// Mark bought: sets or clears the giver's private mark on an open gift, `PATCH /gifts/{id}` with only
    /// `is_bought`.
    case markBought(giftID: String, isBought: Bool)

    /// Set the from label: who an open gift is from, `PATCH /gifts/{id}` with only `from_label`. Nil clears it.
    case setFromLabel(giftID: String, fromLabel: String?)

    /// Write the note: the giver's private note on an open gift, `PATCH /gifts/{id}` with only `note`. Nil clears
    /// it.
    case setNote(giftID: String, note: String?)

    /// Lower how many: `PATCH /gifts/{id}` with only `quantity`. A raise is never an unsent change: it is a claim,
    /// and waits for the server (see "Claims are online only" in `docs/spec.md`).
    case lowerQuantity(giftID: String, quantity: Int)

    /// I won't get this: the giver unclaims their open gift, `DELETE /gifts/{id}`. The gift leaves the copy at once,
    /// and the quantity goes back to all givers when the server accepts it.
    case unclaim(giftID: String)

    /// OK, or Keep it: the giver answers one flag of their open gift, `POST /gifts/{id}/acknowledge` with only that
    /// flag's code. Keep it is the answer to `removed`. The code is the server's text, such as `changed`.
    case acknowledge(giftID: String, flag: String)

    /// Pick the occasion: `PATCH /gifts/{id}` with only `occasion_id`. When the giver has another open gift on the
    /// item for that occasion, the server merges the two, and its answer is the gift that stays.
    case setOccasion(giftID: String, occasion: PickedOccasion)

    /// Edit list: a new name or description, `PATCH /lists/{id}` with only the fields that change. An empty
    /// description clears it.
    case editList(listID: String, changes: ListChanges)

    /// Delete list: `DELETE /lists/{id}`. The list and its items leave the copy at once.
    case deleteList(listID: String)

    /// Accept: the invited user, or their parent, accepts an invitation, `POST /invitations/{id}/accept`. The
    /// invitation leaves the copy at once, and the list moves into the user's own lists, or into the child's part.
    case acceptInvitation(AcceptedInvitation)

    /// Decline: the invited user, or their parent, declines an invitation, `DELETE /invitations/{id}`. The
    /// invitation leaves the copy at once.
    case declineInvitation(invitationID: String)

    /// Upload a photo: `POST /images` with the bytes of the photo that the user took or chose, for an item that
    /// they added by hand. The ID is the image's stand-in ID, which the item's create names. The bytes wait in the
    /// journal, beside the change, until the upload is sent or refused. Nothing shows for it: the item shows no
    /// image until the server's answers come.
    case uploadImage(imageID: String)

    /// Add an item filled in by hand: `POST /lists/{id}/items`. The item shows at the end of its list at once, by
    /// its stand-in ID, and the server's ID takes its place when the answer comes.
    case createItem(CreatedItem)

    /// Edit item: `PATCH /items/{id}` with only the fields that change. A new photo is an upload before it, which the
    /// change names by the image's stand-in ID until the upload's answer gives the server's. An item that a create
    /// in the journal makes is named by its stand-in ID, until the create's answer gives the server's.
    case editItem(itemID: String, changes: ItemChanges)

    /// Delete item: `DELETE /items/{id}`. The item leaves the copy at once, and its list counts one fewer. An item
    /// that a create in the journal makes is named by its stand-in ID, as for an edit.
    case deleteItem(itemID: String, listID: String)
  }
}

/// An item that the user filled in by hand and added as an unsent change, with what its row shows until the
/// server answers. See "When the instance can't be reached" in `docs/spec.md`.
public struct CreatedItem: Sendable, Equatable {
  /// The item's stand-in ID. See `StandIn`.
  public let id: String
  public let listID: String
  public let title: String
  public let notes: String?
  public let priceMinor: Int?
  public let topPriceMinor: Int?
  public let currency: String?

  /// The store links, with their stores: the link that the user gave, kept as the store link.
  public let storeLinks: [SearchStoreLink]

  /// The images, the primary first: the server's ID of an image that is uploaded, or the stand-in ID of an upload
  /// that waits. An upload that the server refused is left out when the create is sent.
  public let imageIDs: [String]

  /// The user who added it: the session's user.
  public let addedByID: String

  /// Whether the session's user is a recipient of the list, so the item shows no claim state, as the server hides
  /// it from a recipient.
  public let hidesClaimState: Bool
  public let createdAt: Date

  init(
    id: String, listID: String, item: NewItem, storeLinks: [SearchStoreLink], addedByID: String,
    hidesClaimState: Bool, createdAt: Date
  ) {
    self.init(
      id: id, listID: listID, title: item.title, notes: item.notes, priceMinor: item.priceMinor,
      topPriceMinor: item.topPriceMinor, currency: item.currency, storeLinks: storeLinks, imageIDs: item.imageIDs,
      addedByID: addedByID, hidesClaimState: hidesClaimState, createdAt: createdAt)
  }

  public init(
    id: String, listID: String, title: String, notes: String?, priceMinor: Int?, topPriceMinor: Int?,
    currency: String?, storeLinks: [SearchStoreLink], imageIDs: [String], addedByID: String,
    hidesClaimState: Bool, createdAt: Date
  ) {
    self.id = id
    self.listID = listID
    self.title = title
    self.notes = notes
    self.priceMinor = priceMinor
    self.topPriceMinor = topPriceMinor
    self.currency = currency
    self.storeLinks = storeLinks
    self.imageIDs = imageIDs
    self.addedByID = addedByID
    self.hidesClaimState = hidesClaimState
    self.createdAt = createdAt
  }

  /// The body that the create sends, as the add form makes it. An image that is still a stand-in was never
  /// uploaded, because the server refused its upload: the item goes without it.
  var newItem: NewItem {
    NewItem(
      title: title, notes: notes, priceMinor: priceMinor, topPriceMinor: topPriceMinor, currency: currency,
      storeLinks: storeLinks.map { link in
        NewStoreLink(url: link.url, priceMinor: link.priceMinor, currency: link.currency, imageURL: link.imageURL)
      },
      imageIDs: imageIDs.filter { !StandIn.isStandIn($0) })
  }
}

/// A stand-in ID: the ID of a thing that a create in the journal makes, until the server's answer gives its own.
/// Later changes, the copy and each window refer to the thing by it meanwhile. When the answer comes, the server's
/// ID takes its place in the copy and in the changes that wait, and the journal keeps which ID took the place of
/// which, so a page that a window opened by the stand-in shows the thing still. See "Unsent changes" in
/// `docs/spec.md`.
///
/// A stand-in can't be taken for a server's ID: it has a prefix that no server's ID has, and a UUID. It needs no
/// escape in JSON, so the journal can put the server's ID in its place in a patch's text.
public enum StandIn {
  static let prefix = "stand-in-"

  /// A new stand-in ID.
  static func make() -> String {
    prefix + UUID().uuidString.lowercased()
  }

  /// Whether the ID is a stand-in, and not the server's.
  public static func isStandIn(_ id: String) -> Bool {
    id.hasPrefix(prefix)
  }
}

/// An invitation that the user accepted, with what the copy shows until the server answers: the list, by its ID
/// and name, and the user who becomes its recipient. The invited user may not see the list yet, so the copy can have
/// no row for it: the list then shows by its name, with the inviter and the invited user as its recipients.
public struct AcceptedInvitation: Sendable, Equatable {
  public let invitationID: String
  public let listID: String
  public let listName: String

  /// The invited user: the session's user, or one of their children.
  public let userID: String

  /// The recipient who invited them. Nil once that user is deleted.
  public let invitedByID: String?

  /// When the invitation was made: what the list shows as made, until the server answers.
  public let createdAt: Date

  public init(_ invitation: InvitationRow) {
    self.init(
      invitationID: invitation.id, listID: invitation.listID, listName: invitation.listName,
      userID: invitation.userID, invitedByID: invitation.invitedByID, createdAt: invitation.createdAt)
  }

  init(invitationID: String, listID: String, listName: String, userID: String, invitedByID: String?, createdAt: Date) {
    self.invitationID = invitationID
    self.listID = listID
    self.listName = listName
    self.userID = userID
    self.invitedByID = invitedByID
    self.createdAt = createdAt
  }
}

extension UnsentChange {
  /// What the server answered an unsent change with: the thing as it has it now, or nothing.
  enum Answer: Sendable {
    case gift(Versioned<Gift>)
    case list(Versioned<ListResource>)

    /// The answer of an upload: the image, by the server's ID.
    case image(ImageSummary)

    /// The answer of a create: the item, by the server's ID.
    case item(Versioned<Item>)

    /// No answer to keep: an unclaim, a delete, or an answer that the app couldn't read. The next pull brings the
    /// row.
    case none

    var gift: Versioned<Gift>? {
      if case .gift(let gift) = self { gift } else { nil }
    }

    var list: Versioned<ListResource>? {
      if case .list(let list) = self { list } else { nil }
    }

    /// The server's ID of what a create made. Nil for any other answer.
    var createdID: String? {
      switch self {
      case .image(let image): image.id
      case .item(let item): item.resource.id
      case .gift, .list, .none: nil
      }
    }
  }
}

/// An occasion that a giver picked for a gift, with what the gift shows until the server answers: its kind and
/// name, and its next date when it was picked. See "Pick the occasion" in `docs/screens/gift.md`.
public struct PickedOccasion: Sendable, Equatable, Codable {
  public let id: String
  public let kind: OccasionKind
  public let name: String

  /// The occasion's next date when the giver picked it, as `YYYY-MM-DD`: the gift's occasion date.
  public let date: String

  public init(id: String, kind: OccasionKind, name: String, date: String) {
    self.id = id
    self.kind = kind
    self.name = name
    self.date = date
  }
}

/// A change that the server refused after the app had applied it: the app rolled it back, and says so once, the
/// next time a window comes to the foreground. See "Late refusals" in `docs/spec.md`.
public struct LateRefusal: Sendable, Equatable, Identifiable {
  public let id: Int64

  /// What the refused change did.
  public let action: UnsentChange.Action

  /// The title of what it changed, as it was when the change was made.
  public let title: String

  /// The server's refusal. The app shows its own words for the code.
  public let refusal: APIError.Refusal

  public init(id: Int64, action: UnsentChange.Action, title: String, refusal: APIError.Refusal) {
    self.id = id
    self.action = action
    self.title = title
    self.refusal = refusal
  }
}

/// The late refusals that one window shows, in its one alert, "Some changes couldn't be saved".
public struct LateRefusalAlert: Sendable, Equatable {
  /// The window that came to the foreground. Only it shows the alert.
  public let window: UUID
  public let refusals: [LateRefusal]
}

// MARK: - The journal's tables

/// An unsent change, as the journal's table keeps it.
struct UnsentChangeRow: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
  static let databaseTableName = "unsentChange"

  /// Nil until the row is saved. The journal's order.
  var id: Int64?

  /// What the change does, by the name of its action.
  var kind: Kind

  /// The server's ID of what the change is to.
  var targetID: String

  /// The merge patch that the change sends, as JSON: only the fields that it changes.
  var patch: String

  var key: String
  var title: String
  var createdAt: Date

  /// The names of the actions, as the journal keeps them. A name never changes, and never goes: a journal that a
  /// later version of the app wrote must still read.
  enum Kind: String, Codable, Sendable {
    case markBought
    case setFromLabel
    case setNote
    case lowerQuantity
    case unclaim
    case acknowledge
    case setOccasion
    case editList
    case deleteList
    case acceptInvitation
    case declineInvitation
    case uploadImage
    case createItem
    case editItem
    case deleteItem
  }

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

/// The bytes of a photo that an upload in the journal sends, by the upload's stand-in ID. It is in the session's
/// database, in the session's own folder, never in the shared container: it carries through every migration of the
/// copy, leaves with its upload, and goes with the database at sign-out and at the API's own 401. The journal reads
/// it only to send it, so the snapshot never reads the bytes.
struct UnsentFileRow: Codable, Sendable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "unsentFile"

  var id: String
  var data: Data
}

/// A stand-in ID that the server's ID took the place of. See `StandIn`.
struct StandInRow: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "standIn"

  var id: String
  var serverID: String
}

/// A late refusal, as the journal's table keeps it until a window shows it.
struct LateRefusalRow: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
  static let databaseTableName = "lateRefusal"

  var id: Int64?
  var kind: UnsentChangeRow.Kind
  var targetID: String
  var patch: String
  var title: String

  /// The refusal: the route, by its name, the status, the server's code, and its `detail`, which the app shows only
  /// for a code that it doesn't know.
  var route: String
  var status: Int
  var code: String
  var detail: String

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

extension LocalDatabase {
  /// Makes the journal's tables, and brings them up to date. Each step of the journal is a migration of its own, by
  /// its name, and is never changed or removed once it has shipped.
  ///
  /// **The migrator never erases the database** (`eraseDatabaseOnSchemaChange` stays false): the database holds
  /// the copy too, and a migrator that erased it for a schema it didn't know would lose the unsent changes. A
  /// migration that the migrator doesn't know, which a later version of the app ran, is left as it is.
  static func prepareJournal(in writer: any DatabaseWriter) throws {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("journal 1") { database in
      try database.create(table: UnsentChangeRow.databaseTableName) { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("kind", .text).notNull()
        table.column("targetID", .text).notNull()
        table.column("patch", .text).notNull()
        table.column("key", .text).notNull()
        table.column("title", .text).notNull()
        table.column("createdAt", .datetime).notNull()
      }
      try database.create(table: LateRefusalRow.databaseTableName) { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("kind", .text).notNull()
        table.column("targetID", .text).notNull()
        table.column("patch", .text).notNull()
        table.column("title", .text).notNull()
        table.column("route", .text).notNull()
        table.column("status", .integer).notNull()
        table.column("code", .text).notNull()
        table.column("detail", .text).notNull()
      }
    }
    migrator.registerMigration("journal 2") { database in
      try database.create(table: UnsentFileRow.databaseTableName) { table in
        table.primaryKey("id", .text)
        table.column("data", .blob).notNull()
      }
      try database.create(table: StandInRow.databaseTableName) { table in
        table.primaryKey("id", .text)
        table.column("serverID", .text).notNull()
      }
    }
    try migrator.migrate(writer)
  }

  // MARK: - What the journal reads

  /// The oldest unsent change: the next one to send. Nil when the journal holds none.
  func firstUnsentChange() async throws -> UnsentChange? {
    try await writer.read { database in try Self.unsentChanges(in: database).first }
  }

  /// How many unsent changes the journal holds.
  func unsentChangeCount() async throws -> Int {
    try await writer.read { database in try UnsentChangeRow.fetchCount(database) }
  }

  /// Whether an unsent change of how many waits for the gift.
  func hasUnsentQuantityChange(toGift id: String) async throws -> Bool {
    try await writer.read { database in
      try UnsentChangeRow
        .filter(Column("kind") == UnsentChangeRow.Kind.lowerQuantity.rawValue && Column("targetID") == id)
        .fetchCount(database) > 0
    }
  }

  /// The late refusals that no window has shown yet, the oldest first.
  func lateRefusals() async throws -> [LateRefusal] {
    try await writer.read { database in try Self.lateRefusals(in: database) }
  }

  // MARK: - What the journal writes

  /// Saves an unsent change at the end of the journal, with a key of its own. Every window shows it at once.
  func record(_ action: UnsentChange.Action, title: String) async throws {
    try await record([NewChange(action, title: title)])
  }

  /// An unsent change to save: its action, its title, its key, and the bytes that it sends, for an upload.
  struct NewChange: Sendable {
    let action: UnsentChange.Action
    let title: String
    let key: String
    let file: Data?

    init(_ action: UnsentChange.Action, title: String, key: String = UUID().uuidString, file: Data? = nil) {
      self.action = action
      self.title = title
      self.key = key
      self.file = file
    }
  }

  /// Saves the unsent changes at the end of the journal, in order, with the bytes of each upload, in one change:
  /// every window shows them together. A create keeps the key that it was given, such as the add form's, so a
  /// send after an Add whose answer was lost is the same write. A stand-in ID that the server's ID took the place
  /// of is saved as the server's ID.
  func record(_ changes: [NewChange]) async throws {
    let now = Date.now
    let rows = try changes.map { change in
      try UnsentChangeRow(change.action, title: change.title, key: change.key, createdAt: now)
    }
    let files = changes.compactMap { change in
      change.file.map { UnsentFileRow(id: change.action.targetID, data: $0) }
    }
    try await change { database in
      // A create's answer may have put the server's ID in the place of a stand-in that a change names, since the
      // session read the copy: the change names the server's ID, as the changes that waited do.
      let standIns = try Self.standIns(in: database)
      for row in rows {
        var row = row
        if let serverID = standIns[row.targetID] { row.targetID = serverID }
        for (standIn, serverID) in standIns where row.patch.contains(standIn) {
          row.patch = row.patch.replacingOccurrences(of: standIn, with: serverID)
        }
        try row.insert(database)
      }
      for file in files {
        try file.insert(database)
      }
    }
  }

  /// The bytes that the upload with the stand-in ID sends. Nil when the journal holds none.
  func unsentFile(_ id: String) async throws -> Data? {
    try await writer.read { database in try UnsentFileRow.fetchOne(database, key: id)?.data }
  }

  /// The server accepted the change: its answer goes into the copy, and the change leaves the journal, in one
  /// change. From then on, the server is the authority again. With no answer to keep, which the app couldn't read,
  /// only the change leaves, and the next pull brings the row.
  ///
  /// A create's answer gives the server's ID, which takes the place of the stand-in in the changes that wait, in the
  /// same change (see `StandIn`). An upload leaves with its bytes. An item's answer goes into the copy with its store
  /// links, so the item shows by the server's ID in the change that its stand-in leaves in.
  ///
  /// The answer is the thing as the server has it now, with the version that the answer carried. A gift that a
  /// change of occasion merged into another is the gift that stays, so the one with the change's ID leaves the copy.
  /// An unclaim has no answer: the gift leaves the copy with the change. A list's answer is the list, and a delete
  /// has none: the list leaves the copy with its items and its recipient rows. An accept's answer is the list too,
  /// and a decline has none. Either way, the invitation leaves the copy. An item's edit has the item as its answer,
  /// and a delete has none: the item leaves the copy with its store links.
  func accept(_ change: UnsentChange, answer: UnsentChange.Answer) async throws {
    let gift = answer.gift.map { GiftRow($0) }
    let list = answer.list.map { ListRow($0) }
    let item: Versioned<Item>? = if case .item(let item) = answer { item } else { nil }
    try await self.change { database in
      _ = try UnsentChangeRow.deleteOne(database, key: change.id)
      switch change.action {
      case .unclaim(let id): _ = try GiftRow.deleteOne(database, key: id)
      case .deleteList(let id): try Self.removeLists([id], in: database)
      case .acceptInvitation(let invitation):
        _ = try InvitationRow.deleteOne(database, key: invitation.invitationID)
      case .declineInvitation(let id): _ = try InvitationRow.deleteOne(database, key: id)
      case .uploadImage(let id): _ = try UnsentFileRow.deleteOne(database, key: id)
      case .createItem, .editItem: try item.map { try Self.saveAnswered($0, in: database) }
      case .deleteItem(let id, _): try Self.removeItems([id], in: database)
      default: break
      }
      if let serverID = answer.createdID {
        try Self.replace(standIn: change.action.targetID, with: serverID, in: database)
      }
      try list?.save(database)
      guard let gift else { return }
      if gift.id != change.action.targetID { _ = try GiftRow.deleteOne(database, key: change.action.targetID) }
      try gift.save(database)
    }
  }

  /// The server refused the change: it leaves the journal, so the copy shows the server's row again, and the
  /// refusal waits for a window to show it, in one change.
  ///
  /// A refused upload leaves with its bytes. The item's create, or its edit, still names its stand-in, and is sent
  /// without it.
  ///
  /// A refused create leaves with the changes that name its item by its stand-in ID, an edit or a delete, and the
  /// uploads of the photos that those edits add: the server never had the item, so none of them can be sent. Only
  /// the create's refusal shows.
  func refuse(_ change: UnsentChange, refusal: APIError.Refusal) async throws {
    let row = try LateRefusalRow(change, refusal: refusal)
    try await self.change { database in
      _ = try UnsentChangeRow.deleteOne(database, key: change.id)
      if case .uploadImage(let id) = change.action { _ = try UnsentFileRow.deleteOne(database, key: id) }
      if case .createItem(let item) = change.action { try Self.removeChanges(toStandIn: item.id, in: database) }
      var row = row
      try row.insert(database)
    }
  }

  /// Removes the changes that name the item's stand-in ID, and the uploads, with their bytes, of the photos that
  /// those changes add.
  private static func removeChanges(toStandIn itemID: String, in database: Database) throws {
    let dependents = try UnsentChangeRow.filter(Column("targetID") == itemID).fetchAll(database)
    let uploads = dependents.compactMap(UnsentChange.init).flatMap { change -> [String] in
      guard case .editItem(_, let changes) = change.action else { return [] }
      return (changes.imageIDs ?? []).filter(StandIn.isStandIn)
    }
    _ = try UnsentChangeRow.deleteAll(database, keys: dependents.compactMap(\.id))
    try UnsentChangeRow
      .filter(Column("kind") == UnsentChangeRow.Kind.uploadImage.rawValue && uploads.contains(Column("targetID")))
      .deleteAll(database)
    _ = try UnsentFileRow.deleteAll(database, keys: uploads)
  }

  /// Removes the late refusals that a window has shown, so that they never show again.
  func removeLateRefusals(_ ids: [Int64]) async throws {
    try await change { database in
      _ = try LateRefusalRow.deleteAll(database, keys: ids)
    }
  }

  /// Puts the server's ID in the place of the stand-in in every change that waits, as the ID of what it changes
  /// and in its patch, and keeps which ID took the place of which.
  private static func replace(standIn: String, with serverID: String, in database: Database) throws {
    guard StandIn.isStandIn(standIn) else { return }
    let table = UnsentChangeRow.databaseTableName.quotedDatabaseIdentifier
    try database.execute(
      sql: "UPDATE \(table) SET targetID = ? WHERE targetID = ?", arguments: [serverID, standIn])
    try database.execute(
      sql: "UPDATE \(table) SET patch = replace(patch, ?, ?) WHERE instr(patch, ?) > 0",
      arguments: [standIn, serverID, standIn])
    try StandInRow(id: standIn, serverID: serverID).save(database)
  }

  /// Saves the item that a create's answer gave, with its store links, as a pull saves an item. No body carries a
  /// store link's version, so the next pull compares them.
  private static func saveAnswered(_ item: Versioned<Item>, in database: Database) throws {
    try removeItems([item.resource.id], in: database)
    try ItemRow(item).save(database)
    for (position, link) in item.resource.storeLinks.enumerated() {
      try StoreLinkRow(link, ofItem: item.resource.id, at: position, version: "").save(database)
    }
  }

  /// Every stand-in ID that the server's ID took the place of, with that ID.
  static func standIns(in database: Database) throws -> [String: String] {
    var standIns: [String: String] = [:]
    for row in try StandInRow.fetchAll(database) {
      standIns[row.id] = row.serverID
    }
    return standIns
  }

  // MARK: - Over the copy

  /// The lists, each with the unsent changes to it applied in order over its row, by name. A deleted list is left
  /// out, and so are its items and recipient rows, which the snapshot shows only for the lists that it has.
  ///
  /// An accepted invitation adds the invited user to the list's recipients. A list that the copy doesn't hold, which
  /// the invited user can't see yet, shows by its name, with no items, until the server's answer brings it. An item
  /// that a create adds counts on its list, and one that a delete takes out counts no more.
  static func applying(_ changes: [UnsentChange], to lists: [ListRow]) -> [ListRow] {
    var rows = lists
    var renamed = false
    for change in changes {
      switch change.action {
      case .editList(let id, let changes):
        guard let index = rows.firstIndex(where: { $0.id == id }) else { continue }
        rows[index] = rows[index].with(changes)
        renamed = renamed || changes.name != nil
      case .deleteList(let id):
        rows.removeAll { $0.id == id }
      case .acceptInvitation(let invitation):
        if let index = rows.firstIndex(where: { $0.id == invitation.listID }) {
          rows[index] = rows[index].with(recipient: invitation.userID)
        } else {
          rows.append(ListRow(standingInFor: invitation))
          renamed = true
        }
      case .createItem(let item):
        guard let index = rows.firstIndex(where: { $0.id == item.listID }) else { continue }
        rows[index] = rows[index].with(itemCount: rows[index].itemCount + 1)
      case .deleteItem(_, let listID):
        guard let index = rows.firstIndex(where: { $0.id == listID }) else { continue }
        rows[index] = rows[index].with(itemCount: max(0, rows[index].itemCount - 1))
      default:
        continue
      }
    }
    // A new name moves the list, as the copy orders the lists: by name, as SQLite compares text, then by ID.
    guard renamed else { return rows }
    return rows.sorted { first, second in
      guard first.name != second.name else { return first.id.utf8.lexicographicallyPrecedes(second.id.utf8) }
      return first.name.utf8.lexicographicallyPrecedes(second.name.utf8)
    }
  }

  /// The invitations, without the ones that an unsent change accepts or declines.
  static func applying(_ changes: [UnsentChange], to invitations: [InvitationRow]) -> [InvitationRow] {
    let answered = Set(
      changes.compactMap { change -> String? in
        switch change.action {
        case .acceptInvitation(let invitation): invitation.invitationID
        case .declineInvitation(let id): id
        default: nil
        }
      })
    guard !answered.isEmpty else { return invitations }
    return invitations.filter { !answered.contains($0.id) }
  }

  /// The items, with the unsent changes to them applied in the journal's order: each item that a create adds goes
  /// after the last item of its list, by its stand-in ID, an edit shows over its row, and a delete takes it out. So
  /// an edit or a delete of an item that a create adds, by its stand-in ID, shows too. The items are in the copy's
  /// order: by list, then by place.
  static func applying(_ changes: [UnsentChange], to items: [ItemRow]) -> [ItemRow] {
    guard changes.contains(where: \.action.isToAnItem) else { return items }
    var last: [String: Int] = [:]
    for item in items {
      last[item.listID] = max(last[item.listID] ?? -1, item.position)
    }
    var rows = items
    for change in changes {
      switch change.action {
      case .createItem(let item):
        let position = (last[item.listID] ?? -1) + 1
        last[item.listID] = position
        rows.append(ItemRow(standingInFor: item, at: position))
      case .editItem(let id, let changes):
        guard let index = rows.firstIndex(where: { $0.id == id }) else { continue }
        rows[index] = rows[index].with(changes)
      case .deleteItem(let id, _):
        rows.removeAll { $0.id == id }
      default:
        continue
      }
    }
    return rows
  }

  /// The store links, with the store links of each item that a create adds, in the order that the user gave them,
  /// and without those of an item that a delete takes out.
  static func applying(_ changes: [UnsentChange], to storeLinks: [StoreLinkRow]) -> [StoreLinkRow] {
    var rows = storeLinks
    for change in changes {
      switch change.action {
      case .createItem(let item):
        rows += item.storeLinks.enumerated().map { position, link in
          StoreLinkRow(standingInFor: link, of: item, at: position)
        }
      case .deleteItem(let id, _):
        rows.removeAll { $0.itemID == id }
      default:
        continue
      }
    }
    return rows
  }

  /// The gifts, each with the unsent changes to it applied in order over its row. An unclaimed gift is left out.
  /// `now` is when a gift is said to be given within 14 days, for `needs_attention` after an answer to a flag or a
  /// pick of the occasion.
  ///
  /// A pick of the occasion for which the giver has another open gift on the item merges the two, as the server
  /// does: the other gift takes this one in, and this one is left out. See "Occasions for a gift" in the server's
  /// spec.
  static func applying(_ changes: [UnsentChange], to gifts: [GiftRow], now: Date = .now) -> [GiftRow] {
    guard !changes.isEmpty else { return gifts }
    var rows = gifts
    var picked = false
    for change in changes where change.action.isToAGift {
      guard let index = rows.firstIndex(where: { $0.id == change.action.targetID }) else { continue }
      let gift = rows[index]
      switch change.action {
      case .markBought(_, let isBought): rows[index] = gift.with(isBought: .shown(isBought))
      case .setFromLabel(_, let fromLabel): rows[index] = gift.with(fromLabel: fromLabel)
      case .setNote(_, let note): rows[index] = gift.with(note: .shown(note))
      case .lowerQuantity(_, let quantity): rows[index] = gift.with(quantity: quantity)
      case .unclaim: rows.remove(at: index)
      case .acknowledge(_, let flag): rows[index] = gift.answering(flag, now: now)
      case .editList, .deleteList, .acceptInvitation, .declineInvitation, .uploadImage, .createItem, .editItem,
        .deleteItem:
        continue
      case .setOccasion(_, let occasion):
        picked = true
        if let staying = rows.firstIndex(where: { gift.mergesInto($0, for: occasion.id) }) {
          rows[staying] = rows[staying].takingIn(gift, now: now)
          rows.remove(at: index)
        } else {
          rows[index] = gift.moved(to: occasion, now: now)
        }
      }
    }
    // A pick moves the reveal, so the soonest reveal is first again, as the copy reads the rows.
    guard picked else { return rows }
    return rows.sorted { $0.revealAt != $1.revealAt ? $0.revealAt < $1.revealAt : $0.id < $1.id }
  }

  /// Every unsent change, in the journal's order.
  static func unsentChanges(in database: Database) throws -> [UnsentChange] {
    try UnsentChangeRow.order(Column("id")).fetchAll(database).compactMap(UnsentChange.init)
  }

  /// Every late refusal that waits, the oldest first.
  static func lateRefusals(in database: Database) throws -> [LateRefusal] {
    try LateRefusalRow.order(Column("id")).fetchAll(database).compactMap(LateRefusal.init)
  }
}

// MARK: - Between the rows and the values

extension UnsentChange.Action {
  /// The server's ID of what the change is to.
  var targetID: String {
    switch self {
    case .markBought(let id, _), .setFromLabel(let id, _), .setNote(let id, _), .lowerQuantity(let id, _),
      .unclaim(let id), .acknowledge(let id, _), .setOccasion(let id, _), .editList(let id, _), .deleteList(let id),
      .declineInvitation(let id):
      id
    case .acceptInvitation(let invitation):
      invitation.invitationID
    case .uploadImage(let id):
      id
    case .createItem(let item):
      item.id
    case .editItem(let id, _), .deleteItem(let id, _):
      id
    }
  }

  /// Whether the change is to a gift. Otherwise it is to a list, to an invitation, to an item, or a create.
  var isToAGift: Bool {
    switch self {
    case .editList, .deleteList, .acceptInvitation, .declineInvitation, .uploadImage, .createItem, .editItem,
      .deleteItem:
      false
    default: true
    }
  }

  /// Whether the change adds an item, or changes one: what the items of the copy show over their rows.
  var isToAnItem: Bool {
    switch self {
    case .createItem, .editItem, .deleteItem: true
    default: false
    }
  }

  /// The merge patch of a change to a gift: only the fields that it changes. An unclaim, or an answer to a flag, is
  /// no patch: it sends nothing, or only the flag's code.
  var giftChanges: GiftChanges {
    switch self {
    case .markBought(_, let isBought): GiftChanges(isBought: isBought)
    // The server clears a from label or a note for an empty string, as for null.
    case .setFromLabel(_, let fromLabel): GiftChanges(fromLabel: fromLabel ?? "")
    case .setNote(_, let note): GiftChanges(note: note ?? "")
    case .lowerQuantity(_, let quantity): GiftChanges(quantity: quantity)
    case .setOccasion(_, let occasion): GiftChanges(occasionID: occasion.id)
    case .unclaim, .acknowledge, .editList, .deleteList, .acceptInvitation, .declineInvitation, .uploadImage,
      .createItem, .editItem, .deleteItem:
      GiftChanges()
    }
  }

  fileprivate var kind: UnsentChangeRow.Kind {
    switch self {
    case .markBought: .markBought
    case .setFromLabel: .setFromLabel
    case .setNote: .setNote
    case .lowerQuantity: .lowerQuantity
    case .unclaim: .unclaim
    case .acknowledge: .acknowledge
    case .setOccasion: .setOccasion
    case .editList: .editList
    case .deleteList: .deleteList
    case .acceptInvitation: .acceptInvitation
    case .declineInvitation: .declineInvitation
    case .uploadImage: .uploadImage
    case .createItem: .createItem
    case .editItem: .editItem
    case .deleteItem: .deleteItem
    }
  }

  /// The patch as the journal keeps it: the JSON that the change sends. An answer to a flag keeps its code, a pick
  /// of the occasion keeps what it shows too, and an unclaim keeps an empty object. An accept sends no body, and
  /// keeps what the list shows until the server answers. A create keeps its body and what its row shows, and an
  /// upload keeps an empty object: its bytes wait beside it. An item's edit keeps its body, and a delete keeps the
  /// item's list, which counts one fewer until the server answers.
  fileprivate func patch() throws -> String {
    let data =
      switch self {
      case .acknowledge(_, let flag): try JSONEncoder().encode(FlagAnswer(codes: [flag]))
      case .setOccasion(_, let occasion): try JSONEncoder().encode(OccasionPick(occasion))
      case .editList(_, let changes): try JSONEncoder().encode(changes)
      case .acceptInvitation(let invitation): try JSONEncoder().encode(AcceptancePatch(invitation))
      case .createItem(let item): try JSONEncoder().encode(CreationPatch(item))
      case .editItem(_, let changes): try JSONEncoder().encode(changes)
      case .deleteItem(_, let listID): try JSONEncoder().encode(DeletionPatch(listID: listID))
      default: try JSONEncoder().encode(giftChanges)
      }
    return String(decoding: data, as: UTF8.self)
  }

  /// The action of a row of the journal. Nil for a patch that the app can't read.
  fileprivate init?(kind: UnsentChangeRow.Kind, targetID: String, patch: String) {
    switch kind {
    case .unclaim:
      self = .unclaim(giftID: targetID)
      return
    case .acknowledge:
      guard let answer = try? JSONDecoder().decode(FlagAnswer.self, from: Data(patch.utf8)),
        answer.codes.count == 1, let flag = answer.codes.first
      else { return nil }
      self = .acknowledge(giftID: targetID, flag: flag)
      return
    case .setOccasion:
      guard let pick = try? JSONDecoder().decode(OccasionPick.self, from: Data(patch.utf8)) else { return nil }
      self = .setOccasion(giftID: targetID, occasion: pick.occasion)
      return
    case .editList:
      guard let changes = try? JSONDecoder().decode(ListChanges.self, from: Data(patch.utf8)), !changes.isEmpty
      else { return nil }
      self = .editList(listID: targetID, changes: changes)
      return
    case .deleteList:
      self = .deleteList(listID: targetID)
      return
    case .acceptInvitation:
      guard let patch = try? JSONDecoder().decode(AcceptancePatch.self, from: Data(patch.utf8)) else { return nil }
      self = .acceptInvitation(patch.invitation(targetID))
      return
    case .declineInvitation:
      self = .declineInvitation(invitationID: targetID)
      return
    case .uploadImage:
      self = .uploadImage(imageID: targetID)
      return
    case .createItem:
      guard let patch = try? JSONDecoder().decode(CreationPatch.self, from: Data(patch.utf8)) else { return nil }
      self = .createItem(patch.item(targetID))
      return
    case .editItem:
      guard let changes = try? JSONDecoder().decode(ItemChanges.self, from: Data(patch.utf8)), !changes.isEmpty
      else { return nil }
      self = .editItem(itemID: targetID, changes: changes)
      return
    case .deleteItem:
      guard let patch = try? JSONDecoder().decode(DeletionPatch.self, from: Data(patch.utf8)) else { return nil }
      self = .deleteItem(itemID: targetID, listID: patch.listID)
      return
    case .markBought, .setFromLabel, .setNote, .lowerQuantity:
      break
    }
    guard let changes = try? JSONDecoder().decode(GiftChanges.self, from: Data(patch.utf8)) else { return nil }
    switch kind {
    case .markBought:
      guard let isBought = changes.isBought else { return nil }
      self = .markBought(giftID: targetID, isBought: isBought)
    case .setFromLabel:
      guard let fromLabel = changes.fromLabel else { return nil }
      self = .setFromLabel(giftID: targetID, fromLabel: fromLabel.isEmpty ? nil : fromLabel)
    case .setNote:
      guard let note = changes.note else { return nil }
      self = .setNote(giftID: targetID, note: note.isEmpty ? nil : note)
    case .lowerQuantity:
      guard let quantity = changes.quantity else { return nil }
      self = .lowerQuantity(giftID: targetID, quantity: quantity)
    case .unclaim, .acknowledge, .setOccasion, .editList, .deleteList, .acceptInvitation, .declineInvitation,
      .uploadImage, .createItem, .editItem, .deleteItem:
      return nil
    }
  }
}

/// An answer to a flag, as the journal keeps it: the codes that it clears, which is always one.
private struct FlagAnswer: Codable {
  let codes: [String]
}

/// A pick of the occasion, as the journal keeps it: the `occasion_id` that it sends, and the kind, name and date
/// that the gift shows until the server answers.
private struct OccasionPick: Codable {
  let occasionID: String
  let kind: String
  let name: String
  let date: String

  enum CodingKeys: String, CodingKey {
    case occasionID = "occasion_id"
    case kind
    case name
    case date
  }

  init(_ occasion: PickedOccasion) {
    occasionID = occasion.id
    kind = occasion.kind.rawValue
    name = occasion.name
    date = occasion.date
  }

  var occasion: PickedOccasion {
    PickedOccasion(id: occasionID, kind: OccasionKind(rawValue: kind), name: name, date: date)
  }
}

/// An accept, as the journal keeps it: what the list shows until the server answers. The accept sends none of it.
private struct AcceptancePatch: Codable {
  let listID: String
  let listName: String
  let userID: String
  let invitedByID: String?
  // JSONEncoder's default date form, seconds since 2001 as a number. Don't change it: a later version of the app must
  // read the journal rows that this one wrote.
  let createdAt: Date

  init(_ invitation: AcceptedInvitation) {
    listID = invitation.listID
    listName = invitation.listName
    userID = invitation.userID
    invitedByID = invitation.invitedByID
    createdAt = invitation.createdAt
  }

  func invitation(_ id: String) -> AcceptedInvitation {
    AcceptedInvitation(
      invitationID: id, listID: listID, listName: listName, userID: userID, invitedByID: invitedByID,
      createdAt: createdAt)
  }
}

/// A delete of an item, as the journal keeps it: the item's list, which counts one fewer until the server answers.
/// The delete sends none of it.
private struct DeletionPatch: Codable {
  let listID: String
}

/// A create of an item, as the journal keeps it: the body that it sends, and what its row shows until the server
/// answers.
private struct CreationPatch: Codable {
  struct Link: Codable {
    let url: String
    let store: String
    let priceMinor: Int?
    let currency: String?
    let imageURL: String?
  }

  let listID: String
  let title: String
  let notes: String?
  let priceMinor: Int?
  let topPriceMinor: Int?
  let currency: String?
  let storeLinks: [Link]
  let imageIDs: [String]
  let addedByID: String
  let hidesClaimState: Bool
  // JSONEncoder's default date form, seconds since 2001 as a number. Don't change it: a later version of the app must
  // read the journal rows that this one wrote.
  let createdAt: Date

  init(_ item: CreatedItem) {
    listID = item.listID
    title = item.title
    notes = item.notes
    priceMinor = item.priceMinor
    topPriceMinor = item.topPriceMinor
    currency = item.currency
    storeLinks = item.storeLinks.map { link in
      Link(
        url: link.url, store: link.store, priceMinor: link.priceMinor, currency: link.currency,
        imageURL: link.imageURL)
    }
    imageIDs = item.imageIDs
    addedByID = item.addedByID
    hidesClaimState = item.hidesClaimState
    createdAt = item.createdAt
  }

  func item(_ id: String) -> CreatedItem {
    CreatedItem(
      id: id, listID: listID, title: title, notes: notes, priceMinor: priceMinor, topPriceMinor: topPriceMinor,
      currency: currency,
      storeLinks: storeLinks.map { link in
        SearchStoreLink(
          url: link.url, store: link.store, priceMinor: link.priceMinor, currency: link.currency,
          imageURL: link.imageURL)
      },
      imageIDs: imageIDs, addedByID: addedByID, hidesClaimState: hidesClaimState, createdAt: createdAt)
  }
}

extension UnsentChange {
  /// The change that a row of the journal keeps. Nil for a row that the app can't read: it stays in the journal,
  /// unsent, and shows nothing.
  fileprivate init?(_ row: UnsentChangeRow) {
    guard let id = row.id, let action = Action(kind: row.kind, targetID: row.targetID, patch: row.patch) else {
      Log.fault(.session, "An unsent change can't be read.")
      return nil
    }
    self.init(id: id, action: action, title: row.title, key: row.key)
  }
}

extension UnsentChangeRow {
  fileprivate init(_ action: UnsentChange.Action, title: String, key: String, createdAt: Date) throws {
    self.init(
      id: nil, kind: action.kind, targetID: action.targetID, patch: try action.patch(), key: key, title: title,
      createdAt: createdAt)
  }
}

extension LateRefusal {
  fileprivate init?(_ row: LateRefusalRow) {
    guard let id = row.id, let action = UnsentChange.Action(kind: row.kind, targetID: row.targetID, patch: row.patch)
    else { return nil }
    self.init(
      id: id, action: action, title: row.title,
      refusal: APIError.Refusal(
        route: Route(rawValue: row.route) ?? .updateGift, status: row.status, code: ErrorCode(row.code),
        detail: row.detail))
  }
}

extension LateRefusalRow {
  fileprivate init(_ change: UnsentChange, refusal: APIError.Refusal) throws {
    self.init(
      id: nil, kind: change.action.kind, targetID: change.action.targetID, patch: try change.action.patch(),
      title: change.title, route: refusal.route.rawValue, status: refusal.status, code: refusal.code.text,
      detail: refusal.detail)
  }
}

extension ListRow {
  /// The list with its name or description changed, as an unsent change shows it over the row. An empty
  /// description clears it.
  fileprivate func with(_ changes: ListChanges) -> ListRow {
    let description = changes.description.map { $0.isEmpty ? nil : $0 } ?? self.description
    return ListRow(
      id: id, name: changes.name ?? name, description: description, isPrimary: isPrimary, recipientIDs: recipientIDs,
      itemCount: itemCount, createdAt: createdAt, canEdit: canEdit, canDelete: canDelete, canInvite: canInvite,
      canLeave: canLeave, version: version)
  }
}

extension ListRow {
  /// The list with one more item, as a create shows it over the row.
  fileprivate func with(itemCount: Int) -> ListRow {
    ListRow(
      id: id, name: name, description: description, isPrimary: isPrimary, recipientIDs: recipientIDs,
      itemCount: itemCount, createdAt: createdAt, canEdit: canEdit, canDelete: canDelete, canInvite: canInvite,
      canLeave: canLeave, version: version)
  }

  /// The list with the user as one more recipient, as an accept shows it over the row. Its `can_*` fields stay the
  /// server's until the answer.
  fileprivate func with(recipient userID: String) -> ListRow {
    guard !recipientIDs.contains(userID) else { return self }
    return ListRow(
      id: id, name: name, description: description, isPrimary: isPrimary, recipientIDs: recipientIDs + [userID],
      itemCount: itemCount, createdAt: createdAt, canEdit: canEdit, canDelete: canDelete, canInvite: canInvite,
      canLeave: canLeave, version: version)
  }

  /// What an accept shows for a list that the copy doesn't hold: its name, and the inviter and the invited user as
  /// its recipients. It has no items and no actions, and no version: it is never saved. The answer brings the list.
  fileprivate init(standingInFor invitation: AcceptedInvitation) {
    self.init(
      id: invitation.listID, name: invitation.listName, description: nil, isPrimary: false,
      recipientIDs: [invitation.invitedByID, invitation.userID].compactMap { $0 }, itemCount: 0,
      createdAt: invitation.createdAt, canEdit: false, canDelete: false, canInvite: false, canLeave: false,
      version: "")
  }
}

extension ItemRow {
  /// What a create shows for its item until the server answers: what the user filled in, at the end of its list,
  /// by its stand-in ID. One is wanted. It has no image yet, and no version: it is never saved.
  ///
  /// A recipient gets no claim state, as the server hides it. Anyone else, such as a parent on a child's list, sees
  /// that nobody has claimed it. The user can edit it, as they could add it. Nothing can claim it or refresh its
  /// prices: those need the server, and the item isn't there yet.
  fileprivate init(standingInFor item: CreatedItem, at position: Int) {
    self.init(
      id: item.id, listID: item.listID, title: item.title, notes: item.notes, priceMinor: item.priceMinor,
      topPriceMinor: item.topPriceMinor, currency: item.currency, quantity: 1, isUnlimited: false,
      position: position, addedByID: item.addedByID, createdAt: item.createdAt, images: [], primaryImage: nil,
      stillWanted: item.hidesClaimState ? .hidden : .shown(1),
      myClaimedQuantity: item.hidesClaimState ? .hidden : .shown(0), canEdit: true, canDelete: true,
      canClaim: false, canRefreshPrices: false, version: "")
  }
}

extension ItemRow {
  /// The item with an edit applied over its row, as an unsent change shows it until the server answers.
  ///
  /// - A price that is cleared clears the top price and the currency with it, as the server does.
  /// - The images are the ones the edit names, in its order, that the row has. A new photo, named by the stand-in
  ///   ID of its upload, shows only when the server's answer comes. The primary image is the one the edit names; else
  ///   the row's, while it stays; else the first that is left.
  /// - How many are still wanted, for a viewer who sees it, moves with how many are wanted. An item that was always
  ///   wanted keeps the server's count until the answer: the copy doesn't know how many were claimed.
  fileprivate func with(_ changes: ItemChanges) -> ItemRow {
    let priceMinor = changes.priceMinor ?? self.priceMinor
    let topPriceMinor = priceMinor == nil ? nil : changes.topPriceMinor ?? self.topPriceMinor
    let currency = priceMinor == nil ? nil : changes.currency ?? self.currency
    let notes = changes.notes.map { $0.isEmpty ? nil : $0 } ?? self.notes
    let quantity = changes.quantity ?? self.quantity
    let isUnlimited = changes.isUnlimited ?? self.isUnlimited
    let images = changes.imageIDs.map { ids in ids.compactMap { id in self.images.first { $0.id == id } } } ?? images
    let primaryImage =
      changes.primaryImageID.flatMap { id in images.first { $0.id == id } }
      ?? primaryImage.flatMap { primary in images.first { $0.id == primary.id } } ?? images.first
    let stillWanted: Hideable<Int> =
      switch self.stillWanted {
      case .hidden: .hidden
      case .shown where isUnlimited: .shown(nil)
      case .shown(let count?) where !self.isUnlimited: .shown(max(0, count + quantity - self.quantity))
      case .shown: self.stillWanted
      }
    return ItemRow(
      id: id, listID: listID, title: changes.title ?? title, notes: notes, priceMinor: priceMinor,
      topPriceMinor: topPriceMinor, currency: currency, quantity: quantity, isUnlimited: isUnlimited,
      position: position, addedByID: addedByID, createdAt: createdAt, images: images, primaryImage: primaryImage,
      stillWanted: stillWanted, myClaimedQuantity: myClaimedQuantity, canEdit: canEdit, canDelete: canDelete,
      canClaim: canClaim, canRefreshPrices: canRefreshPrices, version: version)
  }
}

extension StoreLinkRow {
  /// What a create shows for a store link of its item until the server answers, by an ID made from the item's
  /// stand-in ID. It has no version: it is never saved.
  fileprivate init(standingInFor link: SearchStoreLink, of item: CreatedItem, at position: Int) {
    self.init(
      id: "\(item.id)-link-\(position)", itemID: item.id, position: position, url: link.url, store: link.store,
      priceMinor: link.priceMinor, currency: link.currency, capturedAt: nil, imageURL: link.imageURL,
      createdAt: item.createdAt, canEdit: false, canDelete: false, version: "")
  }
}

extension GiftRow {
  /// The gift with the giver's mark set, as an unsent change shows it over the row.
  fileprivate func with(isBought: Hideable<Bool>) -> GiftRow {
    with(isBought: isBought, fromLabel: fromLabel, note: note, quantity: quantity)
  }

  /// The gift with its from label set, or cleared.
  fileprivate func with(fromLabel: String?) -> GiftRow {
    with(isBought: isBought, fromLabel: fromLabel, note: note, quantity: quantity)
  }

  /// The gift with its note set, or cleared.
  fileprivate func with(note: Hideable<String>) -> GiftRow {
    with(isBought: isBought, fromLabel: fromLabel, note: note, quantity: quantity)
  }

  /// The gift with how many lowered.
  fileprivate func with(quantity: Int) -> GiftRow {
    with(isBought: isBought, fromLabel: fromLabel, note: note, quantity: quantity)
  }

  /// The gift with the flag answered: every flag with the code leaves it. It needs attention while a changed or a
  /// removed flag is left, or while it isn't bought and is given within 14 days, as the server says. It can be
  /// answered while a flag is left.
  fileprivate func answering(_ code: String, now: Date) -> GiftRow {
    guard let flags = flags.value else { return self }
    let left = flags.filter { $0.code != code }
    let needsAttention: Hideable<Bool> =
      switch self.needsAttention {
      case .hidden: .hidden
      case .shown(let was):
        .shown(
          was == true
            && (left.contains { $0.code == "changed" || $0.code == "removed" }
              || (isBought.value != true && revealAt <= now.addingTimeInterval(14 * 24 * 60 * 60)))
        )
      }
    return GiftRow(
      id: id, state: state, quantity: quantity, itemID: itemID, itemTitle: itemTitle,
      itemPrimaryImage: itemPrimaryImage, listID: listID, listName: listName, title: title, image: image,
      priceMinor: priceMinor, topPriceMinor: topPriceMinor, currency: currency, recipientIDs: recipientIDs,
      giverID: giverID, giverName: giverName, fromLabel: fromLabel, occasion: occasion, occasionName: occasionName,
      occasionDate: occasionDate, revealAt: revealAt, givenAt: givenAt, isBought: isBought, note: note,
      flags: .shown(left), needsAttention: needsAttention, createdAt: createdAt, canEdit: canEdit,
      canDelete: canDelete, canRaiseQuantity: canRaiseQuantity, canAcknowledge: canAcknowledge && !left.isEmpty,
      canRestore: canRestore, canAddAgain: canAddAgain, version: version)
  }

  /// Whether a pick of the occasion for this gift merges it into the other gift: the giver's other open gift on the
  /// same item, for that occasion.
  fileprivate func mergesInto(_ other: GiftRow, for occasionID: String) -> Bool {
    other.id != id && other.state == .open && state == .open && other.giverID == giverID && other.itemID == itemID
      && other.occasion?.id == occasionID
  }

  /// The gift moved to the picked occasion: its name, its date, and the reveal that follows it.
  ///
  /// The reveal is the latest midnight, among the recipients' time zones, at the start of the day after the
  /// occasion. The copy doesn't hold every recipient's zone, but the gift's reveal now says how far that midnight is
  /// from the day's start in UTC. The recipients stay the same, so the new reveal is as far from the new day's
  /// start. A change of daylight saving time between the two can move it by an hour, until the server's answer
  /// comes.
  fileprivate func moved(to occasion: PickedOccasion, now: Date) -> GiftRow {
    let revealAt =
      switch (Self.dayAfter(occasionDate), Self.dayAfter(occasion.date)) {
      case (let old?, let new?): new.addingTimeInterval(self.revealAt.timeIntervalSince(old))
      case (nil, let new?): new
      case (_, nil): self.revealAt
      }
    return with(
      quantity: quantity, fromLabel: fromLabel, note: note,
      occasion: OccasionSummary(id: occasion.id, kind: occasion.kind, name: occasion.name),
      occasionName: occasion.name, occasionDate: occasion.date, revealAt: revealAt, flags: flags,
      canAcknowledge: canAcknowledge, now: now)
  }

  /// This gift with the moving gift taken in, as the server merges them: its ID, bought mark and from label stay,
  /// or it takes the moving gift's from label when it has none. The quantities add up, the moving gift's note goes
  /// at the end of this one's, on a new line, and its flags join this one's.
  fileprivate func takingIn(_ moving: GiftRow, now: Date) -> GiftRow {
    let note: Hideable<String> =
      switch (self.note, moving.note) {
      case (.shown(let staying?), .shown(let added?)): .shown(staying + "\n" + added)
      case (.shown(nil), .shown(let added?)): .shown(added)
      default: self.note
      }
    let flags: Hideable<[Flag]> =
      switch (self.flags, moving.flags) {
      case (.shown(let staying), .shown(let added)):
        .shown((staying ?? []) + (added ?? []).filter { !(staying ?? []).contains($0) })
      default: self.flags
      }
    return with(
      quantity: quantity + moving.quantity, fromLabel: fromLabel ?? moving.fromLabel, note: note,
      occasion: occasion, occasionName: occasionName, occasionDate: occasionDate, revealAt: revealAt, flags: flags,
      canAcknowledge: canAcknowledge || moving.canAcknowledge, now: now)
  }

  /// The start of the day after a `YYYY-MM-DD` date, in UTC. Nil for text that is not such a date.
  private static func dayAfter(_ text: String) -> Date? {
    let parts = text.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = .gmt
    return utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2] + 1))
  }

  /// The gift with its occasion, its reveal, how many, its text fields and its flags set, as a pick of the occasion
  /// shows them. It needs attention while a changed or a removed flag is left, or while it isn't bought and is given
  /// within 14 days, as the server says.
  private func with(
    quantity: Int, fromLabel: String?, note: Hideable<String>, occasion: OccasionSummary?, occasionName: String?,
    occasionDate: String, revealAt: Date, flags: Hideable<[Flag]>, canAcknowledge: Bool, now: Date
  ) -> GiftRow {
    let needsAttention: Hideable<Bool> =
      switch self.needsAttention {
      case .hidden: .hidden
      case .shown:
        .shown(
          (flags.value ?? []).contains { $0.code == "changed" || $0.code == "removed" }
            || (isBought.value != true && revealAt <= now.addingTimeInterval(14 * 24 * 60 * 60)))
      }
    return GiftRow(
      id: id, state: state, quantity: quantity, itemID: itemID, itemTitle: itemTitle,
      itemPrimaryImage: itemPrimaryImage, listID: listID, listName: listName, title: title, image: image,
      priceMinor: priceMinor, topPriceMinor: topPriceMinor, currency: currency, recipientIDs: recipientIDs,
      giverID: giverID, giverName: giverName, fromLabel: fromLabel, occasion: occasion, occasionName: occasionName,
      occasionDate: occasionDate, revealAt: revealAt, givenAt: givenAt, isBought: isBought, note: note,
      flags: flags, needsAttention: needsAttention, createdAt: createdAt, canEdit: canEdit, canDelete: canDelete,
      canRaiseQuantity: canRaiseQuantity, canAcknowledge: canAcknowledge && !(flags.value ?? []).isEmpty,
      canRestore: canRestore, canAddAgain: canAddAgain, version: version)
  }

  /// The gift with the fields that an unsent change can set, as the change shows them over the row.
  private func with(isBought: Hideable<Bool>, fromLabel: String?, note: Hideable<String>, quantity: Int) -> GiftRow {
    GiftRow(
      id: id, state: state, quantity: quantity, itemID: itemID, itemTitle: itemTitle,
      itemPrimaryImage: itemPrimaryImage, listID: listID, listName: listName, title: title, image: image,
      priceMinor: priceMinor, topPriceMinor: topPriceMinor, currency: currency, recipientIDs: recipientIDs,
      giverID: giverID, giverName: giverName, fromLabel: fromLabel, occasion: occasion, occasionName: occasionName,
      occasionDate: occasionDate, revealAt: revealAt, givenAt: givenAt, isBought: isBought, note: note,
      flags: flags, needsAttention: needsAttention, createdAt: createdAt, canEdit: canEdit, canDelete: canDelete,
      canRaiseQuantity: canRaiseQuantity, canAcknowledge: canAcknowledge, canRestore: canRestore,
      canAddAgain: canAddAgain, version: version)
  }
}

extension ItemChanges {
  /// The patch as an edit sends it. A new photo is named by the server's ID once its upload is sent. One that is
  /// still a stand-in was never uploaded, because the server refused its upload: the item goes without it, and a
  /// primary image that is such a photo is left as the server has it.
  var sent: ItemChanges {
    var sent = self
    sent.imageIDs = imageIDs?.filter { !StandIn.isStandIn($0) }
    if let primary = primaryImageID, StandIn.isStandIn(primary) { sent.primaryImageID = nil }
    return sent
  }
}
