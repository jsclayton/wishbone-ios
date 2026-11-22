import Synchronization
import WishboneSession

/// A network that changes only when the test says so. Each stream that the code under test asked for gets each
/// change.
final class TestNetwork: NetworkChanges {
  private let streams = Mutex<[AsyncStream<Void>.Continuation]>([])
  private let cost = Mutex(false)

  /// Whether the network is expensive or constrained. A test sets it.
  var isExpensiveOrConstrained: Bool {
    get { cost.withLock { $0 } }
    set { cost.withLock { $0 = newValue } }
  }

  func changes() -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    streams.withLock { $0.append(continuation) }
    return stream
  }

  /// The network changes, as when the device joins another Wi-Fi network.
  func change() {
    for stream in streams.withLock({ $0 }) {
      stream.yield()
    }
  }
}
