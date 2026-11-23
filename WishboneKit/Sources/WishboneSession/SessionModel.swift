import Foundation
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

  /// The session's user. Nil until the copy holds it: after a sign-in, the sign-in reads it before the device
  /// publishes the session, and otherwise the first sync brings it.
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
  /// saved under the line "Can't reach {address}". A sync that stops on a fault of the copy leaves it as it was.
  public private(set) var isInstanceUnreachable = false

  /// Whether a sync has succeeded since this session model began. Until one has, the copy has never been seen to
  /// agree with the instance in this launch, so a screen with no rows shows Loading or Can't reach, never its empty
  /// state. A copy that is dropped is dropped when the database opens, before the session model begins, so the
  /// screens are back at Loading or Can't reach until a sync succeeds. See `screenState(hasRows:)`.
  public private(set) var hasSynced = false

  /// Whether a sync runs now.
  public var isSyncing: Bool { running != nil }

  /// The version block that every window shows in place of the profile gate and the tabs. Nil while nothing blocks.
  /// The session stays while a block shows. See "Version checks" in `docs/spec.md`.
  public private(set) var versionBlock: VersionBlock?

  let client: APIClient
  let database: LocalDatabase

  /// The session's image cache. Screens show the instance's images through it. See "Images" in `docs/spec.md`.
  public let images: ImageCache

  /// The fetch of images ahead of time that runs, or the last one. See `fetchImagesAhead()`.
  private var fetchingImages: Task<Void, Never>?
  private let timeZone: TimeZoneSource

  /// What the session model calls when a request gets the API's own 401: the device forgets the session. It returns
  /// when the device is cleared, and this session model has ended.
  let endedByServer: @MainActor (SessionModel) async -> Void

  /// The zone on the user's record, as the instance last gave it in this launch: in the copy's user after a pull
  /// that ended, or in the answer of a report. The outer nil means that no answer has come yet in this launch, so
  /// the app doesn't know the record and reports nothing.
  private var recordedTimeZone: String??
  private var isReportingTimeZone = false

  /// Whether the session is over: the device signed out. An ended session model publishes nothing, and asks the
  /// instance nothing.
  private(set) var hasEnded = false

  /// Stops when the session model goes.
  private var observation: AnyDatabaseCancellable?
  private var checkingVersion: Task<Void, Never>?

  /// The sync that runs. One sync runs at a time.
  private var running: Task<SyncOutcome, Never>?

  /// The sync that was asked for while one runs. It runs once, after it, however many ask for it.
  private var waiting: Task<SyncOutcome, Never>?

  /// The windows of the app that are in the foreground, each by the ID that the window gave.
  private var windowsInForeground: Set<UUID> = []

  /// The timer that syncs every 60 seconds, while it runs. See `updateTimer()`.
  private var timer: Task<Void, Never>?

  /// The clock of the timer.
  private let timerClock: any Clock<Duration>

  /// How long the timer waits between two syncs.
  static let timerInterval = Duration.seconds(60)

  /// Starts a sync at each change of the device's network, until the session model ends.
  private var watchingNetwork: Task<Void, Never>?

  /// Where the session asks iOS for its next background refresh.
  private let refresh: any RefreshScheduler

  /// The least time that the session asks iOS to wait before the next background refresh. iOS decides when it runs.
  static let refreshInterval = Duration.seconds(60 * 60)

  /// Where the sync's breadcrumbs go.
  private let diagnostics: any DiagnosticsReporter

  /// Where the session schedules its reminders, with their words and the clock of the plan.
  let reminders: Reminders

  /// The reminder settings, as the Reminders screen shows them. See `changeReminderSettings(_:)`.
  public internal(set) var reminderSettings: ReminderSettings

  /// Where the session keeps its reminder settings.
  let reminderSettingsFile: ReminderSettingsFile

  /// What iOS lets the app do with its reminders, as the app last read it. Nil until it has read it.
  public internal(set) var reminderAuthorization: ReminderAuthorization?

  /// Whether Show on Lock Screen is asking iOS now. It asks once at a time.
  var isAskingForFullAuthorization = false

  /// The rebuild of the reminders that runs, or the last one. One runs at a time.
  var rebuildingReminders: Task<Void, Never>?

  /// The IANA name of the device's zone now.
  var timeZoneIdentifier: String {
    timeZone.identifier()
  }

  init(
    session: Session,
    client: APIClient,
    database: LocalDatabase,
    imageFolder: URL?,
    timeZone: TimeZoneSource,
    timerClock: any Clock<Duration>,
    network: any NetworkChanges,
    refresh: any RefreshScheduler,
    diagnostics: any DiagnosticsReporter,
    reminders: Reminders,
    reminderSettingsFile: ReminderSettingsFile,
    endedByServer: @escaping @MainActor (SessionModel) async -> Void
  ) {
    self.session = session
    self.client = client
    self.database = database
    images = ImageCache(client: client, folder: imageFolder, network: network)
    self.timeZone = timeZone
    self.timerClock = timerClock
    self.refresh = refresh
    self.diagnostics = diagnostics
    self.reminders = reminders
    self.reminderSettingsFile = reminderSettingsFile
    reminderSettings = reminderSettingsFile.read()
    self.endedByServer = endedByServer
    // The first snapshot comes at once, so a screen shows what is saved before anything is asked of the instance.
    observation = LocalDatabase.snapshots(ofUser: session.userID).start(
      in: database.writer,
      scheduling: .immediate,
      onError: { error in
        Log.fault(.session, "The copy can't be read.", detail: "\(error)")
      },
      onChange: { [weak self] snapshot in
        self?.publish(snapshot)
      }
    )
    // The stream starts now, so a change that comes before the task reads it is not lost.
    let changes = network.changes()
    watchingNetwork = Task { [weak self] in
      for await _ in changes {
        await self?.syncNow()
      }
    }
  }

  /// Publishes a snapshot of the copy.
  private func publish(_ snapshot: LocalDatabase.Snapshot) {
    user = snapshot.user
    primaryList = snapshot.primaryList
    primaryListItems = snapshot.primaryListItems
    publishLists(of: snapshot)
    users = snapshot.users
    usersByID = Dictionary(snapshot.users.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    groups = snapshot.groups
    occasions = snapshot.occasions
    memberships = snapshot.memberships
  }

  /// Reads the copy, and publishes it now, after a write that every window must show at once, such as a claim. The
  /// copy's observation publishes the same snapshot again later.
  func publishNow() async {
    guard let snapshot = try? await database.snapshot(ofUser: session.userID), !hasEnded else { return }
    publish(snapshot)
  }

  /// Publishes the lists of a snapshot, with their items, store links and recipients, and the invitations.
  private func publishLists(of snapshot: LocalDatabase.Snapshot) {
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

  // MARK: - What a screen shows

  /// What a screen shows, from whether it has rows in the copy and from the outcome of the syncs. See "What every
  /// screen shares" in `docs/screens/README.md`, and "Screens read a local copy" in `docs/spec.md`.
  ///
  /// - A screen with rows shows them, under the line "Can't reach {address}" while the last sync found the instance
  ///   unreachable. The line blocks nothing.
  /// - A screen with no rows shows Can't reach while the instance can't be reached, with Try again.
  /// - Otherwise it shows its empty state only after a sync that succeeded, and Loading until one has.
  public func screenState(hasRows: Bool) -> ScreenState {
    if hasRows { return .saved(cantReach: isInstanceUnreachable) }
    if isInstanceUnreachable { return .cantReach }
    return hasSynced ? .empty : .loading
  }

  // MARK: - Sync now

  /// Sync now: brings the instance and the copy in step. A sync sends the unsent changes, then pulls. Pull to
  /// refresh calls it, and so does each other way that a sync starts. See "When the app syncs" in `docs/spec.md`.
  ///
  /// One sync runs at a time. A call during a sync asks for one more sync, which runs once, after it, however many
  /// calls ask for it. Each of those calls returns when that sync ends. While a version block shows, and after the
  /// session ended, no sync starts, and a call returns `.stopped`.
  ///
  /// It returns when its sync ends, with the sync's outcome. When the instance answers with the API's own 401, the
  /// session is over: the call returns when the device has forgotten it.
  @discardableResult
  public func syncNow() async -> SyncOutcome {
    if let waiting { return await waiting.value }
    guard let running else { return await startSync() }
    let next = Task {
      _ = await running.value
      waiting = nil
      // iOS ended the background run that waited for this sync. See `refreshInBackground()`.
      guard !Task.isCancelled else { return SyncOutcome.stopped }
      return await startSync()
    }
    waiting = next
    return await next.value
  }

  /// Asks for one more sync when a sync runs now, after a write that waits for the server has put the server's
  /// answer into the copy. Nothing waits for that sync.
  ///
  /// A pull writes each thing when its answer arrives, and an answer can be older than the write. A pull whose
  /// `GET /versions` was answered before the server made the change removes the new row as absent, and a body
  /// that it fetched before the change puts the old one back. The server is right, and the copy is wrong until a
  /// pull asks again. So one more sync runs after this one: its `GET /versions` comes after the write, and brings
  /// the write back. The kept `ETag` can stay: the write changed the versions, so they no longer match it.
  ///
  /// A pull that started after the server's answer asks after the write too. So with no sync running, nothing more
  /// is needed.
  func syncAgainIfSyncing() {
    guard !hasEnded, running != nil else { return }
    Task { await syncNow() }
  }

  /// Starts a sync, as the one that runs, and returns its outcome when it ends. After a sync that succeeded, it
  /// starts the fetch of images ahead of time, which nothing waits for, and returns when the reminders are rebuilt.
  ///
  /// Neither is part of the sync that runs. The rebuild can wait for iOS, which took more than a minute to answer the
  /// first ask for authorization on a simulator. A sync that waited for it held every later sync, and with them the
  /// line "Can't reach {address}" after the instance went away.
  private func startSync() async -> SyncOutcome {
    guard !hasEnded, versionBlock == nil else { return .stopped }
    let task = Task { await runSync() }
    running = task
    let outcome = await task.value
    if running == task { running = nil }
    // Only a sync that succeeded rebuilds the reminders and fetches images. A failed sync leaves both as they are.
    if outcome == .succeeded, !hasEnded {
      fetchImagesAhead()
      await rebuildReminders()
    }
    return outcome
  }

  /// One sync. Nothing is sent yet: the unsent changes come with their journal.
  ///
  /// Diagnostics: a breadcrumb at its start, and one with its outcome, whatever started it. They name nothing more.
  private func runSync() async -> SyncOutcome {
    diagnostics.leave(.syncStarted)
    let end = await pull()
    if end == .endedByServer {
      // The session is over. No sync starts after this one, and the end of the session waits for no sync: this one
      // is over.
      hasEnded = true
      running = nil
      updateTimer()
      await endedByServer(self)
    }
    let outcome = syncEnded(end)
    diagnostics.leave(.syncEnded(outcome.end))
    return outcome
  }

  /// Fetches each item's primary image and each avatar that the image cache doesn't hold yet, on a network that is
  /// neither expensive nor constrained. It runs after each sync that succeeded, and the sync doesn't wait for it.
  /// One fetch runs at a time: the next one starts when it ends, and fetches only what is still missing.
  private func fetchImagesAhead() {
    let earlier = fetchingImages
    fetchingImages = Task { [database, images] in
      // A cancelled fetch cancels the one it waits for, so the end of the session stops the whole chain.
      await withTaskCancellationHandler {
        await earlier?.value
      } onCancel: {
        earlier?.cancel()
      }
      guard !Task.isCancelled, let wanted = try? await database.imagesToFetchAhead() else { return }
      await images.fetchAhead(wanted)
    }
  }

  /// Waits until the fetch of images ahead of time, after the last sync that succeeded, has ended. It returns at
  /// once when none runs.
  public func imagesFetchedAhead() async {
    // A sync that ended meanwhile starts the next fetch: wait for that one too.
    while let fetching = fetchingImages {
      await fetching.value
      if fetchingImages == fetching { return }
    }
  }

  /// Where every sync ends, and gets its outcome. It publishes whether the instance could be reached, and starts or
  /// stops the timer. Work that follows a sync that succeeded goes here. An ended session model does nothing here.
  private func syncEnded(_ end: PullEnd) -> SyncOutcome {
    let outcome: SyncOutcome =
      switch end {
      case .succeeded: .succeeded
      case .unreachable: .unreachable
      case .refused, .faulted, .endedByServer: .stopped
      }
    guard !hasEnded else { return outcome }
    switch end {
    case .succeeded:
      isInstanceUnreachable = false
      hasSynced = true
    case .refused: isInstanceUnreachable = false
    case .unreachable: isInstanceUnreachable = true
    // A fault of the copy says nothing of the instance. So the line about it stays as it was.
    case .faulted, .endedByServer: break
    }
    updateTimer()
    return outcome
  }

  /// How a pull ended.
  private enum PullEnd {
    /// The pull ran to its end.
    case succeeded
    /// The instance could not be reached. The session goes on.
    case unreachable
    /// The instance answered, and the pull stopped on its answer: a refusal, a version block, or an answer that
    /// can't be decoded. The session goes on.
    case refused
    /// The pull stopped on the copy, which can't be read or written, or on a cancel. The session goes on.
    case faulted
    /// The instance answered with the API's own 401: the session is over.
    case endedByServer
  }

  /// Runs one pull.
  ///
  /// Diagnostics, for each way that a pull stops:
  /// - An unreachable instance, a cancelled request, a 404, and the API's own 401: never.
  /// - An answer that can't be decoded: captured by the client, as the path template and the key path, never a
  ///   value.
  /// - A copy that can't be read or written: never. The spec's captured faults of the database are one that will
  ///   not open, and a migration that drops the copy, which the database captures when it opens.
  private func pull() async -> PullEnd {
    do {
      let user = try await Pull(client: client, database: database, userID: session.userID).run()
      // The instance has just said that the copy's user is the user's record, also when it said so with a 304
      // and the pull fetched nothing.
      if let record = user?.record { recordedTimeZone = .some(record.timezone.value) }
      return .succeeded
    } catch APIError.unreachable {
      // Unreachable never ends the session, and a 401 that is not the API's own is unreachable. The copy keeps
      // what the pull wrote before it stopped.
      return .unreachable
    } catch APIError.unauthorized {
      // The API's own 401: the session was revoked, went a year unused, or its user was deactivated. The server
      // doesn't say which. The device forgets everything.
      return .endedByServer
    } catch APIError.appTooOld {
      // The API's own 410: this version of the app is too old for the instance. The session stays.
      blockAppTooOld()
      return .refused
    } catch APIError.refused(let refusal) where refusal.status == 404 {
      // A 404 for the versions is an instance below the minimum server version. The version check says so, and
      // finds nothing when the 404 was for something else. The copy keeps what the pull wrote before it stopped.
      await checkVersion()
      return .refused
    } catch APIError.cancelled {
      // A sign-out cancels the pull's request. The instance said nothing.
      return .faulted
    } catch let error as APIError {
      // The instance answered. Another refusal, a 401 with another code included, keeps the session. The copy
      // keeps what the pull wrote before it stopped.
      if case .undecodable(let answer) = error {
        Log.fault(
          .session, "An answer of the pull can't be decoded.",
          detail: "\(answer.route.method) \(answer.route.template) \(answer.keyPath)")
      }
      return .refused
    } catch is CancellationError {
      // A sign-out cancels the pull, and the database can throw this from a write that sees it. It is no fault of
      // the copy, so it is not logged as one.
      return .faulted
    } catch {
      Log.fault(.session, "The copy can't be read or written.", detail: "\(error)")
      return .faulted
    }
  }

  // MARK: - The timer

  /// Starts or stops the timer that syncs every 60 seconds, on the timer's clock. It runs while a window is in the
  /// foreground, the instance answers, no version block shows, and the session goes on. So it stops while the
  /// instance can't be reached, and starts again after a sync that reaches it.
  private func updateTimer() {
    let shouldRun = !hasEnded && !windowsInForeground.isEmpty && !isInstanceUnreachable && versionBlock == nil
    if !shouldRun {
      timer?.cancel()
      timer = nil
    } else if timer == nil {
      let clock = timerClock
      timer = Task { [weak self] in
        while true {
          do {
            try await clock.sleep(for: Self.timerInterval)
          } catch {
            return
          }
          guard let self, !Task.isCancelled else { return }
          await self.syncNow()
        }
      }
    }
  }

  // MARK: - Background refresh

  /// A background refresh, which iOS runs when it lets the app: one sync, through Sync now, as every other way that
  /// a sync starts. Then it asks for the next one. See "When the app syncs" in `docs/spec.md`.
  ///
  /// When iOS ends the run early, it cancels the task that calls this. The sync then stops at its next request: the
  /// request in flight is abandoned, and nothing of its answer is written. Each write to the copy is whole, so every
  /// row is the old one or the new one, and the next sync fetches the rest. A sync that waited to start doesn't
  /// start.
  ///
  /// It returns the sync's outcome. After the session ended, it does nothing, asks for nothing, and returns
  /// `.stopped`.
  ///
  /// Diagnostics: the sync's breadcrumbs, as for every sync. A run that iOS ends early is never captured.
  public func refreshInBackground() async -> SyncOutcome {
    guard !hasEnded else { return .stopped }
    let outcome: SyncOutcome
    if Task.isCancelled {
      outcome = .stopped
    } else {
      outcome = await withTaskCancellationHandler {
        await syncNow()
      } onCancel: {
        Task { @MainActor [weak self] in self?.cancelSyncs() }
      }
    }
    if !hasEnded { refresh.requestRefresh(after: Self.refreshInterval) }
    return outcome
  }

  /// Says that the app went to the background: no window of it is in the foreground. The session asks for the next
  /// background refresh. Only the app calls this, never an extension.
  public func wentToBackground() {
    guard !hasEnded else { return }
    refresh.requestRefresh(after: Self.refreshInterval)
  }

  /// Stops the sync that runs, and the one that waits to start, as iOS ends a background run early.
  private func cancelSyncs() {
    running?.cancel()
    waiting?.cancel()
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
    // A sync that waits to start finds the session ended, and starts nothing.
    let running = running
    running?.cancel()
    timer?.cancel()
    timer = nil
    watchingNetwork?.cancel()
    watchingNetwork = nil
    windowsInForeground = []
    _ = await running?.value
    // The device removes every reminder after this, so a rebuild that runs must end first.
    await rebuildingReminders?.value
    // The device removes the image cache's folder after this, so nothing may write to it then. The cache ends
    // first: it cancels its loads in flight, and waits for their writes, so the fetch ahead of time ends at once
    // and a sign-out never waits for a download.
    await images.end()
    fetchingImages?.cancel()
    await fetchingImages?.value
    fetchingImages = nil
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
    hasSynced = false
    versionBlock = nil
    database.close()
  }

  // MARK: - Windows in the foreground

  /// What the app does each time one of its windows comes to the foreground: it runs the version check, syncs, and
  /// then reports the time zone. While a version block shows, it does only the check. While any window is in the
  /// foreground, the timer syncs every 60 seconds. Only the app calls this, never an extension.
  ///
  /// `window` is the window's own ID, the same at each call, so that `leftForeground(window:)` can say that it
  /// left.
  public func cameToForeground(window: UUID) async {
    guard !hasEnded else { return }
    windowsInForeground.insert(window)
    updateTimer()
    await checkVersion()
    guard versionBlock == nil else { return }
    await syncNow()
    await reportTimeZone()
  }

  /// Says that the window left the foreground, or closed. When no window is in the foreground, the timer stops.
  public func leftForeground(window: UUID) {
    windowsInForeground.remove(window)
    updateTimer()
  }

  // MARK: - Version checks

  /// Try again on the block for an instance that is too old: it runs the version check at once. When the check
  /// passes, the block goes, and the session syncs once.
  public func tryVersionCheckAgain() async {
    guard !hasEnded else { return }
    await checkVersion()
    guard versionBlock == nil else { return }
    await syncNow()
  }

  /// Reads `GET /health`, and shows or lifts the block for an instance that is too old. See "Version checks" in
  /// `docs/spec.md`.
  ///
  /// A call during a check waits for that check, and starts no second one. An instance that can't be reached, or
  /// that answers not as the API does, changes nothing: while signed in, both are unreachable, and the sync says
  /// so. The block for an app that is too old stays: only an update of the app lifts it.
  ///
  /// Diagnostics: never. A version block is no fault, and the client has logged the request's outcome.
  func checkVersion() async {
    guard !hasEnded, versionBlock != .appTooOld else { return }
    if let checkingVersion { return await checkingVersion.value }
    let task = Task {
      let check: VersionCheck
      do {
        check = try await client.checkVersion()
      } catch {
        return
      }
      guard !hasEnded, versionBlock != .appTooOld else { return }
      switch check {
      case .passes:
        versionBlock = nil
      case .tooOld(let version, let minimum):
        versionBlock = .instanceTooOld(version: version, minimum: minimum)
      case .noWishbone:
        break
      }
      updateTimer()
    }
    checkingVersion = task
    await task.value
    if checkingVersion == task { checkingVersion = nil }
  }

  /// Shows the block for an app that is too old, after any request got the API's own 410 `api_version_removed`.
  /// It stays until the app is updated, which ends this launch.
  ///
  /// Diagnostics: never. It is no fault of the app.
  func blockAppTooOld() {
    guard !hasEnded else { return }
    versionBlock = .appTooOld
    updateTimer()
  }

  // MARK: - The first sign-in

  /// Reads the session's own user with `GET /users/me`, and saves it to the copy, before the device publishes the
  /// session. So the first screen after "Signing in…" knows whether the profile gate shows, however slow the first
  /// pull is. See "The profile gate" in `docs/spec.md`.
  ///
  /// A read that fails changes nothing: the first sync brings the user, as it does at every launch. A 401 or a 410
  /// is left to that sync too, which ends the session or shows the block.
  ///
  /// Diagnostics: never. The client captures an answer that it can't decode, and logs the request's outcome.
  func readOwnUser() async {
    guard !hasEnded, let answer = try? await client.me() else { return }
    do {
      try await database.save([answer])
      // The copy's observation publishes the row later, on the main queue. The window must see it now, so the row
      // is published here too, and the observation then publishes the same row again.
      guard !hasEnded, let row = try await database.user(session.userID) else { return }
      user = row
      if let record = row.record { recordedTimeZone = .some(record.timezone.value) }
    } catch is CancellationError {
      // The sign-in was cancelled. It is no fault of the copy.
    } catch {
      Log.fault(.session, "The copy can't take the user's record.", detail: "\(error)")
    }
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
    } catch .appTooOld {
      blockAppTooOld()
    } catch {
      // Diagnostics: never. A failed report is not captured, and not a breadcrumb: the next foreground sends it
      // again. It changes nothing, not even whether the instance can be reached: the sync decides that. The client
      // has logged the request's outcome.
    }
  }
}
