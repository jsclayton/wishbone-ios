import Dispatch
import Network
import Synchronization

/// The device's network, as far as the session needs it: when it changes, and what it costs. Each change starts a
/// sync. See "When the app syncs" in `docs/spec.md`.
public protocol NetworkChanges: Sendable {
  /// Yields once for each change of the device's network after the call. The stream ends when the task that reads it
  /// is cancelled.
  func changes() -> AsyncStream<Void>

  /// Whether the device's network now is expensive, such as cellular or a personal hotspot, or constrained, as Low
  /// Data Mode makes it. The app fetches no image ahead of time on such a network. See "Images" in `docs/spec.md`.
  var isExpensiveOrConstrained: Bool { get }
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

  public var isExpensiveOrConstrained: Bool {
    let path = Self.current.currentPath
    return path.isExpensive || path.isConstrained
  }

  /// The monitor that reads the network as it is now. It starts once, and runs while the app does.
  private static let current: NWPathMonitor = {
    let monitor = NWPathMonitor()
    monitor.start(queue: DispatchQueue(label: "wishbone.network.current"))
    return monitor
  }()
}

/// A network that never changes: the default of a device, so a test sees no change that it didn't make.
public struct UnchangingNetwork: NetworkChanges {
  public init() {}

  public func changes() -> AsyncStream<Void> {
    AsyncStream { _ in }
  }

  /// It is never expensive or constrained, so a test that doesn't say otherwise sees images fetched after a sync.
  public var isExpensiveOrConstrained: Bool { false }
}

extension NetworkChanges where Self == SystemNetwork {
  /// The system's network.
  public static var system: SystemNetwork { SystemNetwork() }
}

extension NetworkChanges where Self == UnchangingNetwork {
  /// A network that never changes.
  public static var unchanging: UnchangingNetwork { UnchangingNetwork() }
}
