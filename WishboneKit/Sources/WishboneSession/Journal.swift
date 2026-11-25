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
  }

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
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
    let row = try UnsentChangeRow(action, title: title, key: UUID().uuidString, createdAt: .now)
    try await change { database in
      var row = row
      try row.insert(database)
    }
  }

  /// The server accepted the change: its answer goes into the copy, and the change leaves the journal, in one
  /// change. From then on, the server is the authority again. With no answer to keep, which the app couldn't read,
  /// only the change leaves, and the next pull brings the row.
  ///
  /// The answer is the thing as the server has it now, with the version that the answer carried. A gift that a
  /// change of occasion merged into another is the gift that stays, so the one with the change's ID leaves the copy.
  /// An unclaim has no answer: the gift leaves the copy with the change.
  func accept(_ change: UnsentChange, answer gift: Versioned<Gift>?) async throws {
    let row = gift.map { GiftRow($0) }
    try await self.change { database in
      _ = try UnsentChangeRow.deleteOne(database, key: change.id)
      if case .unclaim(let id) = change.action { _ = try GiftRow.deleteOne(database, key: id) }
      guard let row else { return }
      if row.id != change.action.targetID { _ = try GiftRow.deleteOne(database, key: change.action.targetID) }
      try row.save(database)
    }
  }

  /// The server refused the change: it leaves the journal, so the copy shows the server's row again, and the
  /// refusal waits for a window to show it, in one change.
  func refuse(_ change: UnsentChange, refusal: APIError.Refusal) async throws {
    let row = try LateRefusalRow(change, refusal: refusal)
    try await self.change { database in
      _ = try UnsentChangeRow.deleteOne(database, key: change.id)
      var row = row
      try row.insert(database)
    }
  }

  /// Removes the late refusals that a window has shown, so that they never show again.
  func removeLateRefusals(_ ids: [Int64]) async throws {
    try await change { database in
      _ = try LateRefusalRow.deleteAll(database, keys: ids)
    }
  }

  // MARK: - Over the copy

  /// The gifts, each with the unsent changes to it applied in order over its row. An unclaimed gift is left out.
  /// `now` is when a gift is said to be given within 14 days, for `needs_attention` after an answer to a flag.
  static func applying(_ changes: [UnsentChange], to gifts: [GiftRow], now: Date = .now) -> [GiftRow] {
    guard !changes.isEmpty else { return gifts }
    return gifts.compactMap { gift in
      changes.reduce(Optional(gift)) { gift, change in
        guard let gift, change.action.targetID == gift.id else { return gift }
        return switch change.action {
        case .markBought(_, let isBought): gift.with(isBought: .shown(isBought))
        case .setFromLabel(_, let fromLabel): gift.with(fromLabel: fromLabel)
        case .setNote(_, let note): gift.with(note: .shown(note))
        case .lowerQuantity(_, let quantity): gift.with(quantity: quantity)
        case .unclaim: nil
        case .acknowledge(_, let flag): gift.answering(flag, now: now)
        }
      }
    }
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
      .unclaim(let id), .acknowledge(let id, _):
      id
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
    case .unclaim, .acknowledge: GiftChanges()
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
    }
  }

  /// The patch as the journal keeps it: the JSON that the change sends. An answer to a flag keeps its code, and an
  /// unclaim keeps an empty object.
  fileprivate func patch() throws -> String {
    let data =
      if case .acknowledge(_, let flag) = self {
        try JSONEncoder().encode(FlagAnswer(codes: [flag]))
      } else {
        try JSONEncoder().encode(giftChanges)
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
    case .unclaim, .acknowledge:
      return nil
    }
  }
}

/// An answer to a flag, as the journal keeps it: the codes that it clears, which is always one.
private struct FlagAnswer: Codable {
  let codes: [String]
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
