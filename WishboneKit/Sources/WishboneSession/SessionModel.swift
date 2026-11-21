import GRDB
import Observation
import WishboneAPI

/// The session model: the shared state of one signed-in session. See ADR 0003.
///
/// It owns the local database. Screens read only what it publishes, which comes from the database, and never call
/// the API client. Every window reads the same session model.
@Observable
@MainActor
public final class SessionModel {
  /// The instance and the user of the session.
  public let session: Session

  /// The session's user. Nil until the first sync has filled the copy.
  public private(set) var user: UserRow?

  /// The user's primary list. Nil until the first sync has filled the copy.
  public private(set) var primaryList: ListRow?

  /// The items on the primary list, in the list's order. Empty while `primaryList` is nil: the two change together.
  public private(set) var primaryListItems: [ItemRow] = []

  /// The lists in the copy that the session's user is a recipient of: the primary list first, and then the extra
  /// lists, by name.
  public private(set) var yourLists: [ListRow] = []

  /// Every list in the copy, by name: every list that the session's user can see, with the admin's access not
  /// counted.
  public private(set) var lists: [ListRow] = []

  /// The same lists, by ID.
  private var listsByID: [String: ListRow] = [:]

  /// The items of each list, by the list's ID, in the list's order.
  private var itemsByList: [String: [ItemRow]] = [:]

  /// The store links of each item, by the item's ID.
  private var storeLinksByItem: [String: [StoreLinkRow]] = [:]

  /// The recipient rows of each list, by the list's ID.
  private var recipientsByList: [String: [RecipientRow]] = [:]

  /// Every pending invitation that the copy holds, the oldest first: the user's own, their children's, and the
  /// ones to the lists that the user is a recipient of.
  public private(set) var invitations: [InvitationRow] = []

  /// Every gift that the copy holds, the soonest reveal first: the ones that the session's user gives, and the
  /// given gifts for them or their children. See `giving`, `given`, `received` and `received(by:)`.
  public private(set) var gifts: [GiftRow] = []

  /// Every blocked store that the copy holds, by store. Only the admin's copy has any.
  public private(set) var blockedStores: [BlockedStoreRow] = []

  /// Every user that the copy holds, by name: the ones that the session's user sees in full, and the ones that
  /// the user gets only as a summary inside another resource.
  public private(set) var users: [UserRow] = []

  /// The same users, by ID.
  private var usersByID: [String: UserRow] = [:]

  /// Every group that the copy holds, by name: the groups that the session's user is in, directly or through
  /// nesting. For the admin, it is every group.
  public private(set) var groups: [GroupRow] = []

  /// Every occasion that the copy holds, the soonest first.
  public private(set) var occasions: [OccasionRow] = []

  /// Every membership that the copy holds. See `members(_:of:)`.
  public private(set) var memberships: [MembershipRow] = []

  /// Whether the last sync found that the instance can't be reached. The session stays, and screens show what is
  /// saved under the line "Can't reach {address}".
  public private(set) var isInstanceUnreachable = false

  private let client: APIClient
  private let database: LocalDatabase
  private let timeZone: TimeZoneSource

  /// What the session model calls when a request gets the API's own 401: the device forgets the session. It returns
  /// when the device is cleared, and this session model has ended.
  private let endedByServer: @MainActor (SessionModel) async -> Void

  /// The zone on the user's record, as the instance last gave it in this launch: in the copy's user after a pull
  /// that ended, or in the answer of a report. The outer nil means that no answer has come yet in this launch, so
  /// the app doesn't know the record and reports nothing.
  private var recordedTimeZone: String??
  private var isReportingTimeZone = false

  /// Whether the session is over: the device signed out. An ended session model publishes nothing, and asks the
  /// instance nothing.
  private var hasEnded = false

  /// Stops when the session model goes.
  private var observation: AnyDatabaseCancellable?
  private var syncing: Task<Void, Never>?

  init(
    session: Session,
    client: APIClient,
    database: LocalDatabase,
    timeZone: TimeZoneSource,
    endedByServer: @escaping @MainActor (SessionModel) async -> Void
  ) {
    self.session = session
    self.client = client
    self.database = database
    self.timeZone = timeZone
    self.endedByServer = endedByServer
    // The first snapshot comes at once, so a screen shows what is saved before anything is asked of the instance.
    observation = LocalDatabase.snapshots(ofUser: session.userID).start(
      in: database.writer,
      scheduling: .immediate,
      onError: { error in
        Log.fault(.session, "The copy can't be read.", detail: "\(error)")
      },
      onChange: { [weak self] snapshot in
        self?.user = snapshot.user
        self?.primaryList = snapshot.primaryList
        self?.primaryListItems = snapshot.primaryListItems
        self?.publish(snapshot)
        self?.users = snapshot.users
        self?.usersByID = Dictionary(snapshot.users.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self?.groups = snapshot.groups
        self?.occasions = snapshot.occasions
        self?.memberships = snapshot.memberships
      }
    )
  }

  /// Publishes the lists of a snapshot, with their items, store links and recipients, and the invitations.
  private func publish(_ snapshot: LocalDatabase.Snapshot) {
    lists = snapshot.lists
    listsByID = Dictionary(snapshot.lists.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    itemsByList = snapshot.items
    storeLinksByItem = snapshot.storeLinks
    recipientsByList = snapshot.recipients
    invitations = snapshot.invitations
    gifts = snapshot.gifts
    blockedStores = snapshot.blockedStores
    let own = snapshot.lists.filter { $0.recipientIDs.contains(session.userID) }
    yourLists = own.filter(\.isPrimary) + own.filter { !$0.isPrimary }
  }

  /// The list in the copy with the ID. Nil for a list that is not in the copy: a missing list and a hidden list
  /// are the same here, as they are on the server.
  public func list(id: String) -> ListRow? {
    listsByID[id]
  }

  /// The items on the list, in the list's order. Empty for a list that is not in the copy.
  public func items(onList id: String) -> [ItemRow] {
    itemsByList[id] ?? []
  }

  /// The item in the copy with the ID, on a list that the copy holds. Nil for an item that is not in the copy.
  public func item(id: String) -> ItemRow? {
    itemsByList.values.lazy.flatMap { $0 }.first { $0.id == id }
  }

  /// The store links of the item, in the order that the server gives the session's user.
  public func storeLinks(ofItem id: String) -> [StoreLinkRow] {
    storeLinksByItem[id] ?? []
  }

  /// The recipient rows of the list, in the order they became recipients. Empty for a list that is not in the
  /// copy.
  public func recipients(ofList id: String) -> [RecipientRow] {
    recipientsByList[id] ?? []
  }

  // MARK: - Gifts

  /// Giving: the session's user's open gifts, the soonest reveal first. The server's `?giver_id=me&state=open`.
  public var giving: [GiftRow] {
    gifts.filter { $0.giverID == session.userID && $0.state == .open }
  }

  /// Given: the gifts that the session's user gave, the newest first. The server's
  /// `?giver_id=me&state=given&sort=-given_at`.
  public var given: [GiftRow] {
    Self.newestFirst(gifts.filter { $0.giverID == session.userID && $0.state == .given })
  }

  /// Received: the gifts given to the session's user, the newest first. The server's
  /// `?recipient_id=me&sort=-given_at`.
  public var received: [GiftRow] {
    received(by: session.userID)
  }

  /// The gifts given to the user, the newest first: for a parent, a child's Received. The server's
  /// `?recipient_id={id}&sort=-given_at`. A gift whose recipients are hidden from the session's user is in no
  /// one's.
  public func received(by userID: String) -> [GiftRow] {
    Self.newestFirst(gifts.filter { $0.state == .given && $0.recipientIDs.value?.contains(userID) == true })
  }

  /// How many of the session's user's gifts need their attention. The server's `?needs_attention=true`.
  public var giftsNeedingAttention: Int {
    gifts.count { $0.needsAttention.value == true }
  }

  /// The gift in the copy with the ID. Nil for a gift that is not in the copy.
  public func gift(id: String) -> GiftRow? {
    gifts.first { $0.id == id }
  }

  private static func newestFirst(_ gifts: [GiftRow]) -> [GiftRow] {
    gifts.sorted { first, second in
      let dates = (first.givenAt ?? .distantPast, second.givenAt ?? .distantPast)
      return dates.0 != dates.1 ? dates.0 > dates.1 : first.id < second.id
    }
  }

  /// The user in the copy with the ID, in full or as a summary. Nil for a user who is not in the copy.
  public func user(id: String) -> UserRow? {
    usersByID[id]
  }

  /// The members of a group or of an occasion, as IDs in the server's order.
  ///
  /// **Nil is not "no members".** It says that the copy holds nothing for this membership: the first sync has not
  /// brought it yet, or the session's user can't read it. For example, only the admin reads the groups in a group.
  /// A membership with no members is an empty list.
  public func members(_ kind: MembershipRow.Kind, of ownerID: String) -> [String]? {
    memberships.first { $0.kind == kind && $0.ownerID == ownerID }?.memberIDs
  }

  /// Brings the instance and the copy in step: a sync sends the unsent changes, then pulls. See "When the app
  /// syncs" in `docs/spec.md`.
  ///
  /// A call during a sync waits for that sync, and starts no second one.
  ///
  /// When the instance answers with the API's own 401, the session is over: the sync returns when the device has
  /// forgotten it.
  public func sync() async {
    guard !hasEnded else { return }
    if let syncing { return await syncing.value }
    let task = Task {
      // Nothing is sent yet: the unsent changes come with their journal.
      guard await pull() == .endedByServer else { return }
      // This sync is over, so the end of the session waits for no sync.
      syncing = nil
      await endedByServer(self)
    }
    syncing = task
    await task.value
    if syncing == task { syncing = nil }
  }

  /// How a pull ended.
  private enum PullEnd {
    /// The pull ran, or stopped, and the session goes on.
    case done
    /// The instance answered with the API's own 401: the session is over.
    case endedByServer
  }

  /// Runs one pull, and publishes whether the instance could be reached.
  ///
  /// Diagnostics, for each way that a pull stops:
  /// - An unreachable instance, a cancelled request, a 404, and the API's own 401: never.
  /// - An answer that can't be decoded: captured, as the path template and the key path, never a value.
  /// - A copy that can't be read or written: captured, by its code only.
  ///
  /// Nothing is captured yet: the app has no diagnostics until `WishboneDiagnostics` holds them.
  private func pull() async -> PullEnd {
    do {
      let user = try await Pull(client: client, database: database, userID: session.userID).run()
      isInstanceUnreachable = false
      // The instance has just said that the copy's user is the user's record, also when it said so with a 304
      // and the pull fetched nothing.
      if let record = user?.record { recordedTimeZone = .some(record.timezone.value) }
    } catch APIError.unreachable {
      // Unreachable never ends the session, and a 401 that is not the API's own is unreachable. The copy keeps
      // what the pull wrote before it stopped.
      isInstanceUnreachable = true
    } catch APIError.unauthorized {
      // The API's own 401: the session was revoked, went a year unused, or its user was deactivated. The server
      // doesn't say which. The device forgets everything.
      return .endedByServer
    } catch let error as APIError {
      // The instance answered. What the answer asks of the app is not built yet: a 404 for the versions is an
      // instance below the minimum server version, which the version check tells the person. Another refusal,
      // a 401 with another code included, keeps the session. The copy keeps what the pull wrote before it
      // stopped.
      isInstanceUnreachable = false
      if case .undecodable(let answer) = error {
        Log.fault(
          .session, "An answer of the pull can't be decoded.",
          detail: "\(answer.route.method) \(answer.route.template) \(answer.keyPath)")
      }
    } catch is CancellationError {
      // A sign-out cancels the pull, and the database can throw this from a write that sees it. It is no fault of
      // the copy, so it is not logged as one.
    } catch {
      Log.fault(.session, "The copy can't be read or written.", detail: "\(error)")
    }
    return .done
  }

  // MARK: - The end of the session

  /// Asks the instance once to revoke the session: `DELETE /users/me/sessions/current`. True when the instance
  /// answered that the session is over, false when it could not be reached or refused.
  ///
  /// Diagnostics: never. A failed revoke is not captured, and not a breadcrumb: the device is cleared anyway, and
  /// the client has logged the request's outcome.
  func revokeOnServer() async -> Bool {
    do {
      try await client.revokeCurrentSession()
      return true
    } catch .unauthorized {
      // The server had already ended the session.
      return true
    } catch {
      return false
    }
  }

  /// Ends the session model, as a sign-out does: it cancels a sync under way and waits for it to stop, stops
  /// reading the copy, publishes nothing more, and closes the local database. Any later sync does nothing.
  ///
  /// A request in flight is abandoned, and its answer is never written: the cancelled sync writes nothing more,
  /// and any other answer finds the session model ended.
  func end() async {
    hasEnded = true
    syncing?.cancel()
    await syncing?.value
    observation?.cancel()
    observation = nil
    user = nil
    primaryList = nil
    primaryListItems = []
    yourLists = []
    lists = []
    listsByID = [:]
    itemsByList = [:]
    storeLinksByItem = [:]
    recipientsByList = [:]
    invitations = []
    gifts = []
    blockedStores = []
    users = []
    usersByID = [:]
    groups = []
    occasions = []
    memberships = []
    isInstanceUnreachable = false
    database.close()
  }

  // MARK: - The app comes to the foreground

  /// What the app does each time it comes to the foreground: it syncs, and then reports the time zone. Only the app
  /// calls this, never an extension.
  public func cameToForeground() async {
    guard !hasEnded else { return }
    await sync()
    await reportTimeZone()
  }

  // MARK: - The time zone

  /// Compares the device's zone with the zone on the user's record, and sends `PATCH /users/me` with the device's
  /// IANA name when they differ. It runs after sign-in and at each foreground. See "Time zone" in `docs/spec.md`.
  ///
  /// It shows nothing. A failure changes nothing, and the next foreground tries again. It reports only the
  /// session's own user, never a child.
  func reportTimeZone() async {
    guard !hasEnded, !isReportingTimeZone, case .some(let recorded) = recordedTimeZone else { return }
    let zone = timeZone.identifier()
    guard zone != recorded else { return }
    isReportingTimeZone = true
    defer { isReportingTimeZone = false }
    do {
      let user = try await client.reportTimeZone(zone)
      // The session ended while the answer was on its way. The database is gone, and stays gone.
      guard !hasEnded else { return }
      recordedTimeZone = .some(user.resource.timezone.value)
      // The answer is the user's record as it is now, with its version. With it in the copy, the next pull has no
      // user to fetch. A copy that can't take it changes nothing: the next pull fetches the user.
      try? await database.save([user])
    } catch .unauthorized {
      // The API's own 401 ends the session, as it does for a sync. Diagnostics: never.
      await endedByServer(self)
    } catch {
      // Diagnostics: never. A failed report is not captured, and not a breadcrumb: the next foreground sends it
      // again. It changes nothing, not even whether the instance can be reached: the sync decides that. The client
      // has logged the request's outcome.
    }
  }
}
