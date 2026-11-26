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

    /// No answer to keep: an unclaim, a delete, or an answer that the app couldn't read. The next pull brings the
    /// row.
    case none

    var gift: Versioned<Gift>? {
      if case .gift(let gift) = self { gift } else { nil }
    }

    var list: Versioned<ListResource>? {
      if case .list(let list) = self { list } else { nil }
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
  /// An unclaim has no answer: the gift leaves the copy with the change. A list's answer is the list, and a delete
  /// has none: the list leaves the copy with its items and its recipient rows. An accept's answer is the list too,
  /// and a decline has none. Either way, the invitation leaves the copy.
  func accept(_ change: UnsentChange, answer: UnsentChange.Answer) async throws {
    let gift = answer.gift.map { GiftRow($0) }
    let list = answer.list.map { ListRow($0) }
    try await self.change { database in
      _ = try UnsentChangeRow.deleteOne(database, key: change.id)
      switch change.action {
      case .unclaim(let id): _ = try GiftRow.deleteOne(database, key: id)
      case .deleteList(let id): try Self.removeLists([id], in: database)
      case .acceptInvitation(let invitation):
        _ = try InvitationRow.deleteOne(database, key: invitation.invitationID)
      case .declineInvitation(let id): _ = try InvitationRow.deleteOne(database, key: id)
      default: break
      }
      try list?.save(database)
      guard let gift else { return }
      if gift.id != change.action.targetID { _ = try GiftRow.deleteOne(database, key: change.action.targetID) }
      try gift.save(database)
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

  /// The lists, each with the unsent changes to it applied in order over its row, by name. A deleted list is left
  /// out, and so are its items and recipient rows, which the snapshot shows only for the lists that it has.
  ///
  /// An accepted invitation adds the invited user to the list's recipients. A list that the copy doesn't hold, which
  /// the invited user can't see yet, shows by its name, with no items, until the server's answer brings it.
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
      case .editList, .deleteList, .acceptInvitation, .declineInvitation:
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
    }
  }

  /// Whether the change is to a gift. Otherwise it is to a list, or to an invitation.
  var isToAGift: Bool {
    switch self {
    case .editList, .deleteList, .acceptInvitation, .declineInvitation: false
    default: true
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
    case .unclaim, .acknowledge, .editList, .deleteList, .acceptInvitation, .declineInvitation: GiftChanges()
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
    }
  }

  /// The patch as the journal keeps it: the JSON that the change sends. An answer to a flag keeps its code, a pick
  /// of the occasion keeps what it shows too, and an unclaim keeps an empty object. An accept sends no body, and
  /// keeps what the list shows until the server answers.
  fileprivate func patch() throws -> String {
    let data =
      switch self {
      case .acknowledge(_, let flag): try JSONEncoder().encode(FlagAnswer(codes: [flag]))
      case .setOccasion(_, let occasion): try JSONEncoder().encode(OccasionPick(occasion))
      case .editList(_, let changes): try JSONEncoder().encode(changes)
      case .acceptInvitation(let invitation): try JSONEncoder().encode(AcceptancePatch(invitation))
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
    case .unclaim, .acknowledge, .setOccasion, .editList, .deleteList, .acceptInvitation, .declineInvitation:
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
