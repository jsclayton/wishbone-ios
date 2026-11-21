import Dispatch
import Network
import Synchronization

/// The device's network, as far as the sync needs it: when it changes. Each change starts a sync. See "When the app
/// syncs" in `docs/spec.md`.
public protocol NetworkChanges: Sendable {
  /// Yields once for each change of the device's network after the call. The stream ends when the task that reads it
  /// is cancelled.
  func changes() -> AsyncStream<Void>
}

/// The system's network, through `NWPathMonitor`. Only the app gives it to its device.
public struct SystemNetwork: NetworkChanges {
  public init() {}

  public func changes() -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    let monitor = NWPathMonitor()
    // The monitor gives the path as it is when it starts. That is no change.
    let isFirst = Mutex(true)
    monitor.pathUpdateHandler = { _ in
      let wasFirst = isFirst.withLock { isFirst in
        defer { isFirst = false }
        return isFirst
      }
      if !wasFirst { continuation.yield() }
    }
    continuation.onTermination = { _ in monitor.cancel() }
    monitor.start(queue: DispatchQueue(label: "wishbone.network"))
    return stream
  }
}

/// A network that never changes: the default of a device, so a test sees no change that it didn't make.
public struct UnchangingNetwork: NetworkChanges {
  public init() {}

  public func changes() -> AsyncStream<Void> {
    AsyncStream { _ in }
  }
}

extension NetworkChanges where Self == SystemNetwork {
  /// The system's network.
  public static var system: SystemNetwork { SystemNetwork() }
}

extension NetworkChanges where Self == UnchangingNetwork {
  /// A network that never changes.
  public static var unchanging: UnchangingNetwork { UnchangingNetwork() }
}
