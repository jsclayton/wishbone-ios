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

  /// The items on the primary list, in the list's order.
  public private(set) var primaryListItems: [ItemRow] = []

  /// The lists in the copy that the session's user is a recipient of, the primary list first. The copy holds only
  /// the primary list until the pull brings the user's other lists.
  public var yourLists: [ListRow] {
    primaryList.map { [$0] } ?? []
  }

  /// Every list and every user in the copy, by ID.
  private var lists: [String: ListRow] = [:]
  private var users: [String: UserRow] = [:]

  /// Whether the last sync found that the instance can't be reached. The session stays, and screens show what is
  /// saved under the line "Can't reach {address}".
  public private(set) var isInstanceUnreachable = false

  private let client: APIClient
  private let database: LocalDatabase
  private let timeZone: TimeZoneSource

  /// The zone on the user's record, as the instance last gave it in this launch: in the copy's user after a pull
  /// that ended, or in the answer of a report. The outer nil means that no answer has come yet in this launch, so
  /// the app doesn't know the record and reports nothing.
  private var recordedTimeZone: String??
  private var isReportingTimeZone = false

  /// Stops when the session model goes.
  private var observation: AnyDatabaseCancellable?
  private var syncing: Task<Void, Never>?

  init(session: Session, client: APIClient, database: LocalDatabase, timeZone: TimeZoneSource) {
    self.session = session
    self.client = client
    self.database = database
    self.timeZone = timeZone
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
        self?.lists = snapshot.lists
        self?.users = snapshot.users
      }
    )
  }

  /// The list in the copy with the ID. Nil for a list that is not in the copy: a missing list and a hidden list
  /// are the same here, as they are on the server.
  public func list(id: String) -> ListRow? {
    lists[id]
  }

  /// The user in the copy with the ID. Nil for a user who is not in the copy.
  public func user(id: String) -> UserRow? {
    users[id]
  }

  /// Brings the instance and the copy in step: a sync sends the unsent changes, then pulls. See "When the app
  /// syncs" in `docs/spec.md`.
  ///
  /// A call during a sync waits for that sync, and starts no second one.
  public func sync() async {
    if let syncing { return await syncing.value }
    let task = Task {
      // Nothing is sent yet: the unsent changes come with their journal.
      await pull()
    }
    syncing = task
    await task.value
    syncing = nil
  }

  /// Runs one pull, and publishes whether the instance could be reached.
  ///
  /// Diagnostics, for each way that a pull stops:
  /// - An unreachable instance, a cancelled request, and a 404: never.
  /// - An answer that can't be decoded: captured, as the path template and the key path, never a value.
  /// - A copy that can't be read or written: captured, by its code only.
  ///
  /// Nothing is captured yet: the app has no diagnostics until `WishboneDiagnostics` holds them.
  private func pull() async {
    do {
      let user = try await Pull(client: client, database: database, userID: session.userID).run()
      isInstanceUnreachable = false
      // The instance has just said that the copy's user is the user's record, also when it said so with a 304
      // and the pull fetched nothing.
      if let user { recordedTimeZone = .some(user.timezone) }
    } catch APIError.unreachable {
      // Unreachable never ends the session. The copy keeps what the pull wrote before it stopped.
      isInstanceUnreachable = true
    } catch let error as APIError {
      // The instance answered. What the answer asks of the app is not built yet: the API's own 401 ends the
      // session, and a 404 for the versions is an instance below the minimum server version, which the version
      // check tells the person. The copy keeps what the pull wrote before it stopped.
      isInstanceUnreachable = false
      if case .undecodable(let answer) = error {
        Log.fault(
          .session, "An answer of the pull can't be decoded.",
          detail: "\(answer.route.method) \(answer.route.template) \(answer.keyPath)")
      }
    } catch {
      Log.fault(.session, "The copy can't be read or written.", detail: "\(error)")
    }
  }

  // MARK: - The app comes to the foreground

  /// What the app does each time it comes to the foreground: it syncs, and then reports the time zone. Only the app
  /// calls this, never an extension.
  public func cameToForeground() async {
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
    guard !isReportingTimeZone, case .some(let recorded) = recordedTimeZone else { return }
    let zone = timeZone.identifier()
    guard zone != recorded else { return }
    isReportingTimeZone = true
    defer { isReportingTimeZone = false }
    do {
      let user = try await client.reportTimeZone(zone)
      recordedTimeZone = .some(user.timezone)
    } catch {
      // Diagnostics: never. A failed report is not captured, and not a breadcrumb: the next foreground sends it
      // again. It changes nothing, not even whether the instance can be reached: the sync decides that. The client
      // has logged the request's outcome.
    }
  }
}
