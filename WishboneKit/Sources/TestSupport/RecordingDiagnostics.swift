import Synchronization
import WishboneAPI

/// A diagnostics reporter that keeps what it is given, so a test can check what each place in the code reports.
/// What reaches Sentry is checked at the envelope, in the hosted tests.
public final class RecordingDiagnostics: DiagnosticsReporter {
  private struct Record {
    var faults: [Fault] = []
    var breadcrumbs: [Breadcrumb] = []
    var version: ServerVersion?
  }

  private let record = Mutex(Record())

  public init() {}

  /// Every fault captured, in order.
  public var faults: [Fault] {
    record.withLock { $0.faults }
  }

  /// Every breadcrumb left, in order.
  public var breadcrumbs: [Breadcrumb] {
    record.withLock { $0.breadcrumbs }
  }

  /// The instance's Wishbone version, as it was last given.
  public var version: ServerVersion? {
    record.withLock { $0.version }
  }

  public func capture(_ fault: Fault) {
    record.withLock { $0.faults.append(fault) }
  }

  public func leave(_ breadcrumb: Breadcrumb) {
    record.withLock { $0.breadcrumbs.append(breadcrumb) }
  }

  public func wishboneVersion(_ version: ServerVersion?) {
    record.withLock { $0.version = version }
  }
}
