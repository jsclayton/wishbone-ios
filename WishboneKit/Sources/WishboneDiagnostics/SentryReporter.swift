import Foundation
import Sentry

/// The one file that imports Sentry. See "Diagnostics" in `docs/architecture.md`, and "What may be sent" and "What
/// the SDK reports" in `docs/spec.md`.
///
/// Every feature of the SDK is off unless it is turned on here on purpose. On: crashes, with the out-of-memory and
/// watchdog terminations that the SDK finds, and app hangs, which the SDK reports only while the app is active.
/// Everything else is off.
@MainActor
enum SentryReporter {
  /// Starts the SDK. Its unsent reports, and the crashes it finds at the next launch, are kept in `folder`.
  static func start(dsn: String, environment: String, diagnosticsID: String, folder: URL) {
    SentrySDK.start(options: options(dsn: dsn, environment: environment, diagnosticsID: diagnosticsID, folder: folder))
  }

  /// Stops the SDK, with no wait for what it has not sent.
  static func stop() {
    SentrySDK.close()
  }

  static var isEnabled: Bool {
    SentrySDK.isEnabled
  }

  /// The options of the SDK. ``features(dsn:environment:diagnosticsID:)`` reads them back for the tests.
  ///
  /// Not on the main actor: the SDK calls the closures in the options on its own queues.
  private nonisolated static func options(dsn: String, environment: String, diagnosticsID: String, folder: URL)
    -> Options
  {
    let options = Options()
    options.dsn = dsn
    options.environment = environment
    options.cacheDirectoryPath = folder.path(percentEncoded: false)
    // Turning diagnostics off closes the SDK, and must not wait to send what it holds.
    options.shutdownTimeInterval = 0

    // On: crashes, the terminations that the SDK finds, and app hangs. The SDK reports a hang only while the app is
    // active, so a hang in the background is never reported.
    options.enableCrashHandler = true
    options.enableWatchdogTerminationTracking = true
    options.enableAppHangTracking = true

    // Off: the user and the IP address. The only ID is the app's own.
    options.sendDefaultPii = false
    options.initialScope = { scope in
      scope.setUser(User(userId: diagnosticsID))
      return scope
    }

    // Off: tracing and profiling.
    options.tracesSampleRate = nil
    options.tracesSampler = nil
    options.configureProfiling = nil
    options.enableAutoPerformanceTracing = false
    options.enableNetworkTracking = false
    options.enableFileIOTracing = false
    options.enableCoreDataTracing = false
    #if os(iOS)
      options.enableUIViewControllerTracing = false
      options.enableUserInteractionTracing = false
      options.enablePreWarmedAppStartTracing = false
    #endif
    options.enableTimeToFullDisplayTracing = false
    options.enablePersistingTracesWhenCrashing = false
    options.enableGraphQLOperationTracking = false
    options.tracePropagationTargets = []

    // Off: metrics, logs, release health's sessions, and the SDK's own reports of what it dropped.
    options.enableMetrics = false
    options.enableMetricKit = false
    options.enableLogs = false
    options.enableAutoSessionTracking = false
    options.sendClientReports = false

    // Off: session replay, screenshots, and the view hierarchy.
    #if os(iOS)
      options.sessionReplay.sessionSampleRate = 0
      options.sessionReplay.onErrorSampleRate = 0
      options.attachScreenshot = false
      options.attachViewHierarchy = false
    #endif

    // Off: automatic breadcrumbs, network breadcrumbs, failed requests, and the swizzling that they need.
    options.enableAutoBreadcrumbTracking = false
    options.enableNetworkBreadcrumbs = false
    options.enableCaptureFailedRequests = false
    options.enableSwizzling = false

    // Off: memory near the stack at a crash, which can hold anything that the app had in memory.
    options.enableMemoryIntrospection = false
    options.enableSpotlight = false

    options.beforeSend = { event in scrub(event, diagnosticsID: diagnosticsID) }
    return options
  }

  /// The start of the scrubber: what the SDK adds to every event that the app never sends. The rest of the scrubber
  /// comes with the app's own events.
  ///
  /// - The user is the diagnostics ID, and nothing more.
  /// - The diagnostics ID is the only ID of the device. The SDK's `device_app_hash` is a hash of the vendor ID, which
  ///   would outlive turning diagnostics off and on, so it is dropped.
  /// - The time zone goes only to the family's server, so the culture context, which holds the zone and the
  ///   locale, is dropped, and so are the zone and the locale of the device context.
  private nonisolated static func scrub(_ event: Event, diagnosticsID: String) -> Event? {
    event.user = User(userId: diagnosticsID)
    if var context = event.context {
      context["culture"] = nil
      context["device"]?["timezone"] = nil
      context["device"]?["locale"] = nil
      context["app"]?["device_app_hash"] = nil
      event.context = context
    }
    return event
  }

  /// Each feature of the SDK, on or off, read back from the options that ``start(dsn:environment:diagnosticsID:folder:)``
  /// uses.
  static func features(dsn: String, environment: String, diagnosticsID: String) -> [String: Bool] {
    let options = options(
      dsn: dsn, environment: environment, diagnosticsID: diagnosticsID,
      folder: URL(filePath: "/nonexistent", directoryHint: .isDirectory))
    var features = [
      "crashes": options.enableCrashHandler,
      "watchdog terminations": options.enableWatchdogTerminationTracking,
      "app hangs": options.enableAppHangTracking,
      "user and IP address": options.sendDefaultPii,
      "tracing": options.isTracingEnabled || options.enableAutoPerformanceTracing,
      "network tracing": options.enableNetworkTracking,
      "file tracing": options.enableFileIOTracing,
      "Core Data tracing": options.enableCoreDataTracing,
      "full display tracing": options.enableTimeToFullDisplayTracing,
      "trace propagation": !options.tracePropagationTargets.isEmpty,
      "profiling": options.configureProfiling != nil,
      "metrics": options.enableMetrics || options.enableMetricKit,
      "logs": options.enableLogs,
      "sessions": options.enableAutoSessionTracking,
      "client reports": options.sendClientReports,
      "automatic breadcrumbs": options.enableAutoBreadcrumbTracking,
      "network breadcrumbs": options.enableNetworkBreadcrumbs,
      "failed requests": options.enableCaptureFailedRequests,
      "swizzling": options.enableSwizzling,
      "memory introspection": options.enableMemoryIntrospection,
      "spotlight": options.enableSpotlight,
    ]
    #if os(iOS)
      features["view controller tracing"] = options.enableUIViewControllerTracing
      features["user interaction tracing"] = options.enableUserInteractionTracing
      features["app start tracing"] = options.enablePreWarmedAppStartTracing
      features["session replay"] =
        options.sessionReplay.sessionSampleRate > 0 || options.sessionReplay.onErrorSampleRate > 0
      features["screenshots"] = options.attachScreenshot
      features["view hierarchy"] = options.attachViewHierarchy
    #endif
    return features
  }

  #if DEBUG
    /// For the tests only: a fixed event with no words from the app.
    static func sendProbe() {
      SentrySDK.capture(message: "diagnostics probe")
    }

    /// For the tests only: waits until the SDK has tried to send what it holds.
    static func flush() async {
      await Task.detached { SentrySDK.flush(timeout: 10) }.value
    }
  #endif
}
