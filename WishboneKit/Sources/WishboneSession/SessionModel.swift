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

  /// Whether the last sync found that the instance can't be reached. The session stays, and screens show what is
  /// saved under the line "Can't reach {address}".
  public private(set) var isInstanceUnreachable = false

  private let client: APIClient
  private let database: LocalDatabase

  /// Stops when the session model goes.
  private var observation: AnyDatabaseCancellable?
  private var syncing: Task<Void, Never>?

  init(session: Session, client: APIClient, database: LocalDatabase) {
    self.session = session
    self.client = client
    self.database = database
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
      }
    )
  }

  /// Brings the copy up to date with the instance: it pulls the session's user and their primary list.
  ///
  /// A call during a sync waits for that sync, and starts no second one.
  public func sync() async {
    if let syncing { return await syncing.value }
    let task = Task { await pull() }
    syncing = task
    await task.value
    syncing = nil
  }

  private func pull() async {
    let user: User
    let items: [Item]
    do {
      user = try await client.me()
      items = if let list = user.primaryList { try await client.items(ofList: list.id) } else { [] }
    } catch .unreachable {
      // Unreachable never ends the session.
      isInstanceUnreachable = true
      return
    } catch {
      // The instance answered. What the answer asks of the app (the API's own 401, a version block) is not built
      // yet, so the copy stays as it is.
      isInstanceUnreachable = false
      return
    }
    isInstanceUnreachable = false
    do {
      try await database.save(user: user, primaryListItems: items)
    } catch {
      Log.fault(.session, "The copy can't be written.", detail: "\(error)")
    }
  }
}
