import Foundation
import Sentry
import WishboneAPI

/// The one file that imports Sentry. See "Diagnostics" in `docs/architecture.md`, and "What may be sent" and "What
/// the SDK reports" in `docs/spec.md`.
///
/// Every feature of the SDK is off unless it is turned on here on purpose. On: crashes, with the out-of-memory and
/// watchdog terminations that the SDK finds, and app hangs, which the SDK reports only while the app is active.
/// Everything else is off.
@MainActor
enum SentryReporter {
  /// Starts the SDK. Its unsent reports, and the crashes it finds at the next launch, are kept in `folder`.
  static func start(dsn: String, environment: String, diagnosticsID: String, folder: URL, wishboneVersion: String) {
    SentrySDK.start(
      options: options(
        dsn: dsn, environment: environment, diagnosticsID: diagnosticsID, folder: folder,
        wishboneVersion: wishboneVersion))
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
  private nonisolated static func options(
    dsn: String, environment: String, diagnosticsID: String, folder: URL, wishboneVersion: String = "unknown"
  ) -> Options {
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
    // Every event is tagged with the instance's Wishbone version.
    options.initialScope = { scope in
      scope.setUser(User(userId: diagnosticsID))
      scope.setTag(value: wishboneVersion, key: "wishbone_version")
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
    // Off: the swizzling of `Data` for file tracing, which is off too.
    options.enableDataSwizzling = false

    // Off: memory near the stack at a crash, which can hold anything that the app had in memory.
    options.enableMemoryIntrospection = false
    options.enableSpotlight = false

    // The scrubber: the second net under the closed vocabulary.
    options.beforeSend = { event in scrub(event, diagnosticsID: diagnosticsID) }
    options.beforeBreadcrumb = { breadcrumb in scrub(breadcrumb) }
    return options
  }

  /// The scrubber of every event, in `beforeSend`. First it holds the event to what the app names, then it passes
  /// every string that is left through ``Scrubber/text(_:)``, which strips tokens, login links, hosts, and anything
  /// shaped like an address.
  ///
  /// - The user is the diagnostics ID, and nothing more.
  /// - The diagnostics ID is the only ID of the device. The SDK's `device_app_hash` is a hash of the vendor ID, which
  ///   would outlive turning diagnostics off and on, so it is dropped.
  /// - The time zone goes only to the family's server, so the culture context, which holds the zone and the
  ///   locale, is dropped.
  /// - The contexts are only the app's, the device's, the system's, and a fault's, each held to its own fields. The
  ///   device context keeps only ``deviceFields``: the device's model, and its memory for the out-of-memory reports.
  /// - An image's path names the folder that iOS gives the app at install, with a UUID that outlives turning
  ///   diagnostics off and on. So each image of the debug meta, and each frame's image, keeps only its path inside
  ///   the app's bundle. Symbols are found by the image's debug ID and the address, not by its path.
  /// - Free text of the runtime never goes: an exception's value (a `fatalError` or `precondition` message, the
  ///   reason of an exception), a mechanism's description and data, a thread's name, a frame's source and
  ///   variables, the extra, the modules, the server's name, the logger, the transaction, and the request. An
  ///   exception keeps its type only when it is a name, such as `EXC_BAD_ACCESS`.
  /// - A message is only a fault's name. The tags are only a fault's name and the Wishbone version.
  /// - The breadcrumbs are held to the vocabulary, as `beforeBreadcrumb` holds them.
  private nonisolated static func scrub(_ event: Event, diagnosticsID: String) -> Event? {
    event.user = User(userId: diagnosticsID)
    for image in event.debugMeta ?? [] {
      image.codeFile = image.codeFile.map(Scrubber.pathInsideBundle)
    }

    let fault = event.tags?["fault"].flatMap(Fault.Kind.init(rawValue:))
    if let message = event.message?.formatted, message == fault?.rawValue {
      event.message = SentryMessage(formatted: message)
    } else {
      event.message = nil
    }
    event.fingerprint = fault.map { _ in (event.fingerprint ?? []).map(Scrubber.text) }
    var tags = ["wishbone_version": event.tags?["wishbone_version"].map(Scrubber.text) ?? "unknown"]
    tags["fault"] = fault?.rawValue
    event.tags = tags
    event.extra = nil
    event.modules = nil
    event.serverName = nil
    event.logger = nil
    event.transaction = nil
    event.request = nil
    event.error = nil

    for exception in event.exceptions ?? [] {
      exception.value = nil
      exception.type = Scrubber.name(exception.type)
      exception.module = nil
      if let mechanism = exception.mechanism {
        mechanism.type = Scrubber.name(mechanism.type) ?? "unknown"
        mechanism.desc = nil
        mechanism.data = nil
        mechanism.helpLink = nil
        if let meta = mechanism.meta {
          meta.signal = meta.signal.map(codes)
          meta.machException = meta.machException.map(codes)
          if let error = meta.error {
            meta.error = SentryNSError(domain: Scrubber.name(error.domain) ?? "unknown", code: error.code)
          }
        }
      }
    }
    for thread in event.threads ?? [] {
      thread.name = nil
    }
    let stacktraces =
      (event.threads ?? []).compactMap(\.stacktrace) + (event.exceptions ?? []).compactMap(\.stacktrace)
      + [event.stacktrace].compactMap(\.self)
    for frame in stacktraces.flatMap(\.frames) {
      frame.package = frame.package.map { Scrubber.text(Scrubber.pathInsideBundle($0)) }
      frame.fileName = frame.fileName.map { Scrubber.text(Scrubber.pathInsideBundle($0)) }
      frame.function = frame.function.map(Scrubber.text)
      frame.module = frame.module.map(Scrubber.text)
      frame.contextLine = nil
      frame.preContext = nil
      frame.postContext = nil
      frame.vars = nil
    }

    let context = event.context ?? [:]
    var kept: [String: [String: Any]] = [:]
    kept["app"] = context["app"].map { app in
      fields(app, keeping: appFields).mapValues { value in
        // The app's own bundle ID is the same on every device, and is not a host.
        if let text = value as? String, text == Bundle.main.bundleIdentifier { return text }
        return scrubbed(value)
      }
    }
    kept["device"] = context["device"].map { fields($0, keeping: deviceFields).mapValues(scrubbed) }
    kept["os"] = context["os"].map { fields($0, keeping: osFields).mapValues(scrubbed) }
    kept["fault"] = context["fault"].flatMap { Scrubber.faultFields($0, kind: fault?.rawValue) }
    event.context = kept.isEmpty ? nil : kept

    event.breadcrumbs = event.breadcrumbs?.compactMap(scrub)
    return event
  }

  /// The scrubber of every breadcrumb, in `beforeBreadcrumb`, and of the breadcrumbs of an event. Only a breadcrumb
  /// that the app made is kept: its category is one of the vocabulary's kinds, and its data is that kind's fields,
  /// each with one of its values. It has no message, and nothing else.
  private nonisolated static func scrub(_ breadcrumb: Sentry.Breadcrumb) -> Sentry.Breadcrumb? {
    guard let fields = Scrubber.breadcrumbFields(category: breadcrumb.category, data: breadcrumb.data ?? [:]) else {
      return nil
    }
    let kept = Sentry.Breadcrumb(level: .info, category: breadcrumb.category)
    kept.timestamp = breadcrumb.timestamp
    for (key, value) in fields { kept.setData(value: Scrubber.text(value), key: key) }
    return kept
  }

  /// The fields of a context that are on the list.
  private nonisolated static func fields(_ context: [String: Any], keeping list: Set<String>) -> [String: Any] {
    context.filter { list.contains($0.key) }
  }

  /// A value of a context, with its strings scrubbed.
  private nonisolated static func scrubbed(_ value: Any) -> Any {
    switch value {
    case let text as String: Scrubber.text(text)
    case let list as [Any]: list.map(scrubbed)
    case let fields as [String: Any]: fields.mapValues(scrubbed)
    default: value
    }
  }

  /// A signal's or a Mach exception's fields: numbers, and names such as `SIGSEGV`.
  private nonisolated static func codes(_ fields: [String: Any]) -> [String: Any] {
    fields.compactMapValues { value in
      if let text = value as? String { return Scrubber.name(text) }
      return value as? NSNumber
    }
  }

  /// The fields of the device context that an event keeps. See "What may be sent" in `docs/spec.md`, and
  /// `PRIVACY.md`: the device's model, and its memory.
  nonisolated static let deviceFields: Set<String> = [
    "model", "model_id", "family", "arch", "simulator", "memory_size", "free_memory",
  ]

  /// The fields of the app context that an event keeps: the app's version and build, and its state at the event.
  nonisolated static let appFields: Set<String> = [
    "app_identifier", "app_name", "app_version", "app_build", "build_type", "app_start_time", "app_memory", "app_id",
    "in_foreground", "is_active", "app_arch",
  ]

  /// The fields of the system context that an event keeps: the iOS version.
  nonisolated static let osFields: Set<String> = ["name", "version", "build", "kernel_version"]

  // MARK: - The app's own events

  /// Sends the app's own fault, as the one event type: its name as the message and as a tag, and its fields in its
  /// own context. Nothing else of the app's goes with it.
  nonisolated static func capture(_ fault: Fault) {
    let event = Event(level: .error)
    event.message = SentryMessage(formatted: fault.kind.rawValue)
    event.tags = ["fault": fault.kind.rawValue]
    let fields = fault.fields.mapValues { value -> Any in
      switch value {
      case .word(let word): word
      case .number(let number): number
      }
    }
    event.context = ["fault": fields]
    // Faults of one kind with the same fields are one issue.
    event.fingerprint =
      [fault.kind.rawValue]
      + fault.fields.sorted { $0.key < $1.key }.map { key, value in
        switch value {
        case .word(let word): "\(key)=\(word)"
        case .number(let number): "\(key)=\(number)"
        }
      }
    SentrySDK.capture(event: event)
  }

  /// Leaves the app's own breadcrumb, for the next event.
  nonisolated static func leave(_ breadcrumb: WishboneAPI.Breadcrumb) {
    let crumb = Sentry.Breadcrumb(level: .info, category: breadcrumb.kind.rawValue)
    for (key, value) in breadcrumb.fields { crumb.setData(value: value, key: key) }
    SentrySDK.addBreadcrumb(crumb)
  }

  /// Tags every later event with the instance's Wishbone version.
  nonisolated static func tag(wishboneVersion tag: String) {
    SentrySDK.configureScope { scope in scope.setTag(value: tag, key: "wishbone_version") }
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
      "data swizzling": options.enableDataSwizzling,
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

    /// For the tests only: an event and a breadcrumb with the text in every field that a caller of the SDK can set,
    /// as runtime free text or a careless call could fill them. The scrubber must leave none of it.
    static func sendPlanted(_ text: String) {
      let crumb = Sentry.Breadcrumb(level: .info, category: text)
      crumb.message = text
      crumb.type = text
      crumb.origin = text
      crumb.setData(value: text, key: text)
      crumb.setData(value: text, key: "kind")
      SentrySDK.addBreadcrumb(crumb)
      // A breadcrumb of the app's own kind, with a field that the kind doesn't have.
      let request = Sentry.Breadcrumb(level: .info, category: WishboneAPI.Breadcrumb.Kind.request.rawValue)
      for (key, value) in ["method": "GET", "path": "/users", "status_class": "2xx", "host": text] {
        request.setData(value: value, key: key)
      }
      SentrySDK.addBreadcrumb(request)

      let event = Event(level: .fatal)
      event.message = SentryMessage(formatted: text)
      event.logger = text
      event.serverName = text
      event.transaction = text
      event.dist = nil
      event.tags = [text: text, "fault": text, "wishbone_version": text]
      event.extra = [text: text]
      event.modules = [text: text]
      event.fingerprint = [text]
      event.user = User(userId: text)
      event.user?.email = text
      event.user?.ipAddress = text
      event.user?.username = text
      let request2 = SentryRequest()
      request2.url = text
      request2.queryString = text
      request2.headers = [text: text]
      request2.cookies = text
      event.request = request2
      event.context = [
        text: [text: text],
        "app": [text: text, "app_name": text],
        "device": [text: text, "model": text],
        "os": [text: text, "version": text],
        "fault": [text: text, "code": text],
      ]
      let frame = Frame()
      frame.function = text
      frame.package = text
      frame.fileName = text
      frame.module = text
      frame.contextLine = text
      frame.preContext = [text]
      frame.postContext = [text]
      frame.vars = [text: text]
      let exception = Exception(value: text, type: text)
      exception.module = text
      let mechanism = Mechanism(type: text)
      mechanism.desc = text
      mechanism.data = [text: text]
      mechanism.helpLink = text
      let meta = MechanismContext()
      meta.signal = ["name": text, "number": 11]
      meta.machException = ["name": text, "exception": 1]
      meta.error = SentryNSError(domain: text, code: 1)
      mechanism.meta = meta
      exception.mechanism = mechanism
      exception.stacktrace = SentryStacktrace(frames: [frame], registers: [:])
      event.exceptions = [exception]
      let thread = SentryThread(threadId: 1)
      thread.name = text
      thread.stacktrace = SentryStacktrace(frames: [frame], registers: [:])
      event.threads = [thread]
      SentrySDK.capture(event: event)
    }

    /// For the tests only: waits until the SDK has tried to send what it holds.
    static func flush() async {
      await Task.detached { SentrySDK.flush(timeout: 10) }.value
    }
  #endif
}
