import Synchronization
import WishboneAPI

/// An install marker that is kept in memory: it stands for the app group's shared container. A test gives the same
/// one to a second `Device` to stand for a relaunch, and a new one to stand for a reinstall.
public final class InMemoryInstallMarker: InstallMarker {
  private let present: Mutex<Bool>

  public init(isPresent: Bool = false) {
    present = Mutex(isPresent)
  }

  public var isPresent: Bool {
    present.withLock { $0 }
  }

  public func place() {
    present.withLock { $0 = true }
  }
}
