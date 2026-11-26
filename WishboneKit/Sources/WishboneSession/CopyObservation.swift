import Dispatch
import GRDB
import Synchronization
import WishboneAPI

// The copy's observation: what the session model publishes, read again after each change to the copy.
//
// **Only what a change touched is read again.** The snapshot is made from parts, and each part reads tables of its
// own. A change notes the tables that it wrote, and its commit reads again only the parts that read one of them.
// The rest stay as they were read. A pull writes each thing when its answer arrives, so it makes many small changes,
// and each of them touches one or two tables. A read of the whole copy after each of them decoded every row of the
// copy again for each change.
//
// **The parts are read inside the commit,** on the writer's connection, before the next change can start. So each
// snapshot is the copy as one change left it, and the snapshots come in the order of the changes. A claim's
// `publishNow()` relies on this: the observation read its snapshot of the claim's change before the claim returned,
// and gives it after every older one, so the last snapshot that a window shows is never older than the claim.

extension LocalDatabase {
  /// The rows that the snapshot is made from, as each part reads them.
  struct CopyParts: Sendable {
    /// One part of the snapshot, and the tables that it reads.
    enum Part: CaseIterable, Sendable {
      case lists, items, storeLinks, recipients, invitations, gifts, unsentChangeCount, lateRefusals, blockedStores
      case users, groups, occasions, memberships, standIns

      /// The tables that the part reads. A change to any of them reads the part again.
      ///
      /// The items, the store links and the recipient rows are only those of the lists in the copy, so they read
      /// the lists too, and the store links read the items. The lists, the items, the store links, the invitations
      /// and the gifts show each unsent change over its row, so they read the journal too. The lists read the items,
      /// because a waiting delete or move counts only where the items' overlay applies it.
      var tables: Set<String> {
        switch self {
        case .lists: [ListRow.databaseTableName, ItemRow.databaseTableName, UnsentChangeRow.databaseTableName]
        case .items: [ItemRow.databaseTableName, ListRow.databaseTableName, UnsentChangeRow.databaseTableName]
        case .storeLinks:
          [
            StoreLinkRow.databaseTableName, ItemRow.databaseTableName, ListRow.databaseTableName,
            UnsentChangeRow.databaseTableName,
          ]
        case .recipients: [RecipientRow.databaseTableName, ListRow.databaseTableName]
        case .invitations: [InvitationRow.databaseTableName, UnsentChangeRow.databaseTableName]
        case .gifts: [GiftRow.databaseTableName, UnsentChangeRow.databaseTableName]
        case .unsentChangeCount: [UnsentChangeRow.databaseTableName]
        case .lateRefusals: [LateRefusalRow.databaseTableName]
        case .blockedStores: [BlockedStoreRow.databaseTableName]
        case .users: [UserRow.databaseTableName]
        case .groups: [GroupRow.databaseTableName]
        case .occasions: [OccasionRow.databaseTableName]
        case .memberships: [MembershipRow.databaseTableName]
        case .standIns: [StandInRow.databaseTableName]
        }
      }

      /// Every table that a part reads, in lower case, as SQLite compares table names.
      static let tables = Set(allCases.flatMap(\.tables).map { $0.lowercased() })

      /// The parts that read a table of the ones given, in lower case.
      static func reading(_ tables: Set<String>) -> Set<Part> {
        Set(allCases.filter { part in part.tables.contains { tables.contains($0.lowercased()) } })
      }
    }

    /// The lists of the copy, for a part that reads only what is on them.
    ///
    /// The pull saves a list's items and recipient rows before the list, in changes of their own. Until the list's
    /// change, the snapshot shows none of them, and these parts don't read them: on the first sync, every list's
    /// items would otherwise be read again after each list's items arrived.
    static let listIDs = ListRow.select(Column("id"))

    var lists: [ListRow] = []
    var items: [ItemRow] = []
    var storeLinks: [StoreLinkRow] = []
    var recipients: [RecipientRow] = []
    var invitations: [InvitationRow] = []
    var gifts: [GiftRow] = []
    var unsentChangeCount = 0
    var lateRefusals: [LateRefusal] = []
    var blockedStores: [BlockedStoreRow] = []
    var users: [UserRow] = []
    var groups: [GroupRow] = []
    var occasions: [OccasionRow] = []
    var memberships: [MembershipRow] = []
    var standIns: [String: String] = [:]

    /// Every part, read now.
    init(in database: Database) throws {
      for part in Part.allCases {
        try read(part, in: database)
      }
    }

    /// Reads the part again.
    mutating func read(_ part: Part, in database: Database) throws {
      switch part {
      case .lists:
        // An edit shows over the pulled row, and a deleted list is left out, until the server accepts or refuses it.
        // A delete and a move of an item count only where the item's overlay applies them, so the lists read where
        // the items are, while such a change waits.
        let unsent = try LocalDatabase.unsentChanges(in: database)
        let countsItems = unsent.contains { change in
          switch change.action {
          case .deleteItem, .moveItem: true
          default: false
          }
        }
        lists = LocalDatabase.applying(
          unsent, to: try ListRow.order(Column("name"), Column("id")).fetchAll(database),
          itemLists: countsItems ? try LocalDatabase.itemLists(in: database) : [:])
      case .items:
        // An item that a create adds shows at the end of its list, until the server accepts or refuses it.
        items = LocalDatabase.applying(
          try LocalDatabase.unsentChanges(in: database),
          to: try ItemRow.filter(Self.listIDs.contains(Column("listID")))
            .order(Column("listID"), Column("position"), Column("id")).fetchAll(database))
      case .storeLinks:
        let itemIDs = ItemRow.select(Column("id")).filter(Self.listIDs.contains(Column("listID")))
        storeLinks = LocalDatabase.applying(
          try LocalDatabase.unsentChanges(in: database),
          to: try StoreLinkRow.filter(itemIDs.contains(Column("itemID")))
            .order(Column("itemID"), Column("position"), Column("id")).fetchAll(database))
      case .recipients:
        // The order that they became recipients, as the server gives it. Two can have the same time.
        recipients = try RecipientRow.filter(Self.listIDs.contains(Column("listID")))
          .order(Column("createdAt"), Column("userID")).fetchAll(database)
      case .invitations:
        // An accepted or declined invitation is left out, until the server accepts or refuses the change.
        invitations = LocalDatabase.applying(
          try LocalDatabase.unsentChanges(in: database),
          to: try InvitationRow.order(Column("createdAt"), Column("id")).fetchAll(database))
      case .gifts:
        // The unsent changes show over the pulled rows, until the server accepts or refuses each one.
        let unsent = try LocalDatabase.unsentChanges(in: database)
        gifts = LocalDatabase.applying(
          unsent, to: try GiftRow.order(Column("revealAt"), Column("id")).fetchAll(database))
      case .unsentChangeCount:
        // An upload goes with its item's create, so the count is of what the user did: one for each item.
        unsentChangeCount = try UnsentChangeRow.filter(Column("kind") != UnsentChangeRow.Kind.uploadImage.rawValue)
          .fetchCount(database)
      case .lateRefusals: lateRefusals = try LocalDatabase.lateRefusals(in: database)
      case .blockedStores:
        blockedStores = try BlockedStoreRow.order(Column("store"), Column("id")).fetchAll(database)
      case .users: users = try UserRow.order(Column("name"), Column("id")).fetchAll(database)
      case .groups: groups = try GroupRow.order(Column("name"), Column("id")).fetchAll(database)
      case .occasions:
        occasions = try OccasionRow.order(Column("nextDate").ascNullsLast, Column("name"), Column("id")).fetchAll(
          database)
      case .memberships: memberships = try MembershipRow.order(Column("kind"), Column("ownerID")).fetchAll(database)
      case .standIns: standIns = try LocalDatabase.standIns(in: database)
      }
    }
  }

  /// The snapshot for the user, read now. A write that the screen must see at once, such as a claim, publishes
  /// it, before the observation does.
  func snapshot(ofUser id: String) async throws -> Snapshot {
    try await writer.read { database in
      Snapshot(try CopyParts(in: database), ofUser: id)
    }
  }

  /// Starts the observation of the snapshot for the user. `onChange` gets the snapshot that is saved now, before
  /// this returns, and then a new one after each change to the copy that changes it, on the main actor, in the
  /// order of the changes, until it is cancelled. The caller holds the observer: the writer holds it only weakly.
  ///
  /// `check` is for tests: it gets each snapshot that the observation makes, and the whole copy, read in the same
  /// commit.
  @MainActor
  func observeSnapshots(
    ofUser id: String,
    check: (@Sendable (_ made: Snapshot, _ whole: Snapshot) -> Void)? = nil,
    onChange: @escaping @MainActor (Snapshot) -> Void
  ) -> CopyObserver {
    let observer = CopyObserver(userID: id, check: check, onChange: onChange)
    // The observer comes first, so no change is missed between the read and the observation.
    writer.add(transactionObserver: observer, extent: .observerLifetime)
    do {
      onChange(try writer.read { database in Snapshot(try CopyParts(in: database), ofUser: id) })
    } catch {
      Log.fault(.session, "The copy can't be read.", detail: "\(error)")
    }
    return observer
  }
}

extension LocalDatabase.Snapshot {
  /// The snapshot for the user, from parts read in one change.
  init(_ parts: LocalDatabase.CopyParts, ofUser id: String) {
    self.init()
    update(from: parts, changed: Set(LocalDatabase.CopyParts.Part.allCases), ofUser: id)
  }

  /// Makes again what the changed parts give. What only the other parts give stays as it is.
  mutating func update(
    from parts: LocalDatabase.CopyParts, changed: Set<LocalDatabase.CopyParts.Part>, ofUser id: String
  ) {
    if changed.contains(.lists) { lists = parts.lists }
    if changed.contains(.lists) || changed.contains(.items) {
      // A list that is not in the copy has no items here: the pull saves a list's items before the list, in another
      // change, so the list and its items show in the same snapshot.
      let listIDs = Set(lists.map(\.id))
      var items: [String: [ItemRow]] = [:]
      for item in parts.items where listIDs.contains(item.listID) {
        items[item.listID, default: []].append(item)
      }
      self.items = items
    }
    if changed.contains(.storeLinks) {
      var storeLinks: [String: [StoreLinkRow]] = [:]
      for link in parts.storeLinks {
        storeLinks[link.itemID, default: []].append(link)
      }
      self.storeLinks = storeLinks
    }
    if changed.contains(.lists) || changed.contains(.recipients) {
      // The rows of a list go in the order of the list's own recipients. A row that the list doesn't name yet comes
      // last.
      var rows: [String: [RecipientRow]] = [:]
      for row in parts.recipients {
        rows[row.listID, default: []].append(row)
      }
      var recipients: [String: [RecipientRow]] = [:]
      for list in lists {
        guard let unordered = rows[list.id] else { continue }
        let named = list.recipientIDs.compactMap { id in unordered.first { $0.userID == id } }
        recipients[list.id] = named + unordered.filter { !list.recipientIDs.contains($0.userID) }
      }
      self.recipients = recipients
    }
    if changed.contains(.invitations) { invitations = parts.invitations }
    if changed.contains(.gifts) { gifts = parts.gifts }
    if changed.contains(.unsentChangeCount) { unsentChangeCount = parts.unsentChangeCount }
    if changed.contains(.lateRefusals) { lateRefusals = parts.lateRefusals }
    if changed.contains(.blockedStores) { blockedStores = parts.blockedStores }
    if changed.contains(.users) {
      users = parts.users
      user = users.first { $0.id == id && !$0.isSummary }
    }
    if changed.contains(.groups) { groups = parts.groups }
    if changed.contains(.occasions) { occasions = parts.occasions }
    if changed.contains(.memberships) { memberships = parts.memberships }
    if changed.contains(.standIns) { standIns = parts.standIns }
    if !changed.isDisjoint(with: [.users, .lists, .items]) {
      let listID = user?.record?.primaryListID
      primaryList = listID.flatMap { listID in lists.first { $0.id == listID } }
      primaryListItems = listID.flatMap { items[$0] } ?? []
    }
  }
}

/// The observer of the copy's changes, on the writer's connection. See the top of this file.
///
/// Every call of GRDB's comes on the writer's queue, one at a time. So `reading` is only ever locked there, and
/// waits for nothing. `onChange` is locked from the main actor too, when the observation stops.
final class CopyObserver: TransactionObserver, Sendable {
  /// What the observer has read, and what the change that runs has written.
  private struct Reading {
    /// The parts as the last commit left them. Nil until the first commit reads them all.
    var parts: LocalDatabase.CopyParts?

    /// The last snapshot that the observer gave.
    var snapshot = LocalDatabase.Snapshot()

    /// The tables that the change that runs wrote, in lower case.
    var written: Set<String> = []
  }

  private let userID: String
  private let check: (@Sendable (_ made: LocalDatabase.Snapshot, _ whole: LocalDatabase.Snapshot) -> Void)?
  private let reading = Mutex(Reading())

  /// Nil once the observation stops.
  private let onChange: Mutex<(@MainActor (LocalDatabase.Snapshot) -> Void)?>

  init(
    userID: String,
    check: (@Sendable (_ made: LocalDatabase.Snapshot, _ whole: LocalDatabase.Snapshot) -> Void)?,
    onChange: @escaping @MainActor (LocalDatabase.Snapshot) -> Void
  ) {
    self.userID = userID
    self.check = check
    self.onChange = Mutex(onChange)
  }

  /// Stops the observation. A snapshot that is on its way to the main actor is not given.
  func cancel() {
    onChange.withLock { $0 = nil }
  }

  func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
    LocalDatabase.CopyParts.Part.tables.contains(eventKind.tableName.lowercased())
  }

  func databaseDidChange(with event: DatabaseEvent) {
    let table = event.tableName.lowercased()
    reading.withLock { _ = $0.written.insert(table) }
  }

  /// A change that GRDB can't name: every part is read again.
  func databaseDidChange() {
    reading.withLock { $0.written = LocalDatabase.CopyParts.Part.tables }
  }

  func databaseDidRollback(_ database: Database) {
    reading.withLock { $0.written = [] }
  }

  func databaseDidCommit(_ database: Database) {
    guard onChange.withLock({ $0 != nil }) else { return }
    let userID = userID
    let snapshot = reading.withLock { reading -> LocalDatabase.Snapshot? in
      guard !reading.written.isEmpty else { return nil }
      do {
        let parts: LocalDatabase.CopyParts
        let changed: Set<LocalDatabase.CopyParts.Part>
        if var earlier = reading.parts {
          changed = LocalDatabase.CopyParts.Part.reading(reading.written)
          try database.readOnly {
            // In the order of the parts, so that each commit reads them alike.
            for part in LocalDatabase.CopyParts.Part.allCases where changed.contains(part) {
              try earlier.read(part, in: database)
            }
          }
          parts = earlier
        } else {
          changed = Set(LocalDatabase.CopyParts.Part.allCases)
          parts = try database.readOnly { try LocalDatabase.CopyParts(in: database) }
        }
        reading.parts = parts
        reading.written = []
        var snapshot = reading.snapshot
        snapshot.update(from: parts, changed: changed, ofUser: userID)
        if let check {
          check(
            snapshot,
            LocalDatabase.Snapshot(try database.readOnly { try LocalDatabase.CopyParts(in: database) }, ofUser: userID))
        }
        // A change that leaves the snapshot as it was gives nothing.
        guard snapshot != reading.snapshot else { return nil }
        reading.snapshot = snapshot
        return snapshot
      } catch {
        // The tables stay written, so the next commit reads them again.
        Log.fault(.session, "The copy can't be read.", detail: "\(error)")
        return nil
      }
    }
    guard let snapshot else { return }
    // The main queue runs its blocks in order, so the snapshots come in the order of the changes.
    DispatchQueue.main.async { [self] in
      MainActor.assumeIsolated {
        guard let publish = onChange.withLock({ $0 }) else { return }
        publish(snapshot)
      }
    }
  }
}
