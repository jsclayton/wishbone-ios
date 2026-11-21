import Synchronization
import WishboneAPI

/// A session keychain that keeps its session in memory. A test on macOS uses it in place of the system's Keychain,
/// and gives the same one to a second `Device` to stand for a relaunch.
public final class InMemorySessionKeychain: SessionKeychain {
  private let session: Mutex<Session?>

  public init(_ session: Session? = nil) {
    self.session = Mutex(session)
  }

  public func read() -> Session? {
    session.withLock { $0 }
  }

  public func save(_ session: Session) {
    self.session.withLock { $0 = session }
  }

  public func delete() {
    session.withLock { $0 = nil }
  }
}
