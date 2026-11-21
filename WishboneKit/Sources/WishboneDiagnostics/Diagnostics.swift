import Foundation
import Observation
import Synchronization
import WishboneAPI

/// Diagnostics on this device: the switch, the diagnostics ID, and the rule for when the SDK starts. See "On by
/// default, for each device, after a notice" and "Builds that send nothing" in `docs/spec.md`.
///
/// The choice is the device's, not the user's. It is kept in the app's own defaults, outside the session's storage
/// and outside the shared container, so it survives a sign-out and a change of user, and no extension reads it.
///
/// The SDK starts only when all of these hold: the build has a DSN, the signed-out screen has shown the notice, the
/// switch is on, and a Debug build was launched with ``Build/launchArgument``.
@MainActor
@Observable
public final class Diagnostics {
  /// What the build says about diagnostics.
  public struct Build: Sendable, Equatable {
    /// Where diagnostics go. Empty means that diagnostics never start.
    public var dsn: String

    /// The environment tag, which tells TestFlight builds from App Store builds.
    public var environment: String

    /// Whether this is a Debug build.
    public var isDebug: Bool

    /// Whether the app was launched with ``launchArgument``.
    public var hasLaunchArgument: Bool

    /// The argument that lets a Debug build send. The maintainer's own runs and the tests send nothing without it.
    public static let launchArgument = "-WishboneSendDiagnostics"

    public init(dsn: String, environment: String, isDebug: Bool, hasLaunchArgument: Bool) {
      self.dsn = dsn
      self.environment = environment
      self.isDebug = isDebug
      self.hasLaunchArgument = hasLaunchArgument
    }

    /// The build that runs: its `Info.plist` values, its configuration, and the launch arguments.
    public static var current: Build {
      let info = Bundle.main
      #if DEBUG
        let isDebug = true
      #else
        let isDebug = false
      #endif
      return Build(
        dsn: info.object(forInfoDictionaryKey: "WishboneSentryDSN") as? String ?? "",
        environment: info.object(forInfoDictionaryKey: "WishboneSentryEnvironment") as? String ?? "",
        isDebug: isDebug,
        hasLaunchArgument: ProcessInfo.processInfo.arguments.contains(launchArgument)
      )
    }

    /// Whether the build may send at all: it has a DSN, and a Debug build has the launch argument.
    var maySend: Bool {
      !dsn.trimmingCharacters(in: .whitespaces).isEmpty && (!isDebug || hasLaunchArgument)
    }
  }

  /// Whether diagnostics are on for this device. On by default.
  ///
  /// Off deletes anything not yet sent and the diagnostics ID, and sends nothing more, not even a "turned off"
  /// event. On makes a new ID, and starts the SDK when the rule allows.
  public var isOn: Bool {
    didSet {
      guard isOn != oldValue else { return }
      if isOn { turnOn() } else { turnOff() }
    }
  }

  /// Whether the signed-out screen has shown the notice on this device.
  public private(set) var hasShownNotice: Bool

  /// Whether the SDK runs.
  public private(set) var isRunning = false {
    didSet { recorder.isRunning = isRunning }
  }

  /// Where the app's own faults and breadcrumbs go: the app gives it to its device. It records nothing while the SDK
  /// doesn't run, so with diagnostics off nothing is recorded.
  public nonisolated var reporter: any DiagnosticsReporter {
    recorder
  }

  private let recorder: Recorder

  /// The app's own random ID for this device, while diagnostics are on. It is never the user ID, the server's
  /// session ID, or anything the instance knows.
  public var diagnosticsID: String? {
    defaults.string(forKey: Key.id)
  }

  private let build: Build
  private let defaults: UserDefaults
  private let folder: URL

  /// The keys in the app's own defaults.
  private enum Key {
    static let isOff = "WishboneDiagnostics.isOff"
    static let hasShownNotice = "WishboneDiagnostics.hasShownNotice"
    static let id = "WishboneDiagnostics.id"
    static let wishboneVersion = "WishboneDiagnostics.wishboneVersion"
  }

  /// Reads the switch from `defaults`. It doesn't start the SDK: ``start()`` does.
  ///
  /// `folder` is where the SDK keeps what it has not sent yet: reports, and crashes from an earlier run.
  public init(build: Build, defaults: UserDefaults, folder: URL) {
    self.build = build
    self.defaults = defaults
    self.folder = folder
    recorder = Recorder(defaults: defaults, key: Key.wishboneVersion)
    isOn = !defaults.bool(forKey: Key.isOff)
    hasShownNotice = defaults.bool(forKey: Key.hasShownNotice)
    // While diagnostics are on, the device has an ID.
    if isOn, diagnosticsID == nil { makeID() }
  }

  /// The app's diagnostics: the build that runs, the app's own defaults, and a folder in the app's caches.
  public static func app() -> Diagnostics {
    Diagnostics(
      build: .current, defaults: .standard,
      folder: URL.cachesDirectory.appending(path: "Diagnostics", directoryHint: .isDirectory))
  }

  /// Starts the SDK when the rule allows it. The app calls it at launch. It does nothing when the SDK runs.
  public func start() {
    guard !isRunning, build.maySend, hasShownNotice, isOn, let id = diagnosticsID else { return }
    SentryReporter.start(
      dsn: build.dsn, environment: build.environment, diagnosticsID: id, folder: folder,
      wishboneVersion: recorder.versionTag)
    isRunning = true
  }

  /// The signed-out screen has shown the notice. From now on the SDK may start, on this launch and every later one.
  public func noticeShown() {
    if !hasShownNotice {
      hasShownNotice = true
      defaults.set(true, forKey: Key.hasShownNotice)
    }
    start()
  }

  private func turnOn() {
    defaults.removeObject(forKey: Key.isOff)
    makeID()
    start()
  }

  private func turnOff() {
    defaults.set(true, forKey: Key.isOff)
    defaults.removeObject(forKey: Key.id)
    // Nothing more is recorded from now. What is on disk goes first, so the SDK can't send it while it closes. Then
    // once more, for what it wrote then.
    recorder.isRunning = false
    deleteUnsent()
    if isRunning {
      SentryReporter.stop()
      isRunning = false
    }
    deleteUnsent()
  }

  private func makeID() {
    defaults.set(UUID().uuidString, forKey: Key.id)
  }

  /// Deletes what the SDK has not sent yet: its whole folder.
  private func deleteUnsent() {
    try? FileManager.default.removeItem(at: folder)
  }
}

/// The reporter of the app: it hands each fault and breadcrumb to the SDK while the SDK runs, and drops it otherwise.
/// It keeps the instance's Wishbone version in the app's own defaults, so an event at the next launch is tagged before
/// the app reads `GET /health` again.
nonisolated private final class Recorder: DiagnosticsReporter {
  private struct State {
    var isRunning = false
    var version: ServerVersion?
  }

  private let state: Mutex<State>
  // `UserDefaults` is safe to use from any thread.
  nonisolated(unsafe) private let defaults: UserDefaults
  private let key: String

  init(defaults: UserDefaults, key: String) {
    self.defaults = defaults
    self.key = key
    state = Mutex(State(version: defaults.string(forKey: key).flatMap(ServerVersion.init)))
  }

  var isRunning: Bool {
    get { state.withLock { $0.isRunning } }
    set { state.withLock { $0.isRunning = newValue } }
  }

  /// The tag of the instance's Wishbone version.
  var versionTag: String {
    Scrubber.versionTag(state.withLock { $0.version })
  }

  func capture(_ fault: Fault) {
    guard isRunning else { return }
    SentryReporter.capture(fault)
  }

  func leave(_ breadcrumb: Breadcrumb) {
    guard isRunning else { return }
    SentryReporter.leave(breadcrumb)
  }

  func wishboneVersion(_ version: ServerVersion?) {
    let isRunning = state.withLock { state in
      state.version = version
      return state.isRunning
    }
    if let version { defaults.set(version.text, forKey: key) } else { defaults.removeObject(forKey: key) }
    if isRunning { SentryReporter.tag(wishboneVersion: Scrubber.versionTag(version)) }
  }
}

#if DEBUG
  extension Diagnostics {
    /// For the tests only: an event and a breadcrumb with the text in every field that a caller of the SDK can set,
    /// and the words in each field of runtime free text.
    @_spi(Testing) public func sendPlanted(_ text: String, words: String) {
      guard isRunning else { return }
      SentryReporter.sendPlanted(text, words: words)
    }

    /// For the tests only: sends a fixed probe event, with no words of its own, through the running SDK.
    @_spi(Testing) public func sendProbe() {
      guard isRunning else { return }
      SentryReporter.sendProbe()
    }

    /// For the tests only: the debug ID of the image that ``sendPlanted(_:words:)`` plants.
    @_spi(Testing) public nonisolated static var plantedImageID: String {
      SentryReporter.plantedImageID
    }

    /// For the tests only: the part of a file's path that an event keeps. See ``Scrubber/pathInsideBundle(_:)``.
    @_spi(Testing) public nonisolated static func pathInsideBundle(_ path: String) -> String {
      Scrubber.pathInsideBundle(path)
    }

    /// For the tests only: waits until the SDK has tried to send what it holds.
    @_spi(Testing) public func flush() async {
      await SentryReporter.flush()
    }

    /// For the tests only: whether the SDK itself is enabled.
    @_spi(Testing) public static var isSDKEnabled: Bool {
      SentryReporter.isEnabled
    }

    /// For the tests only: each feature of the SDK, on or off, as the options that ``start()`` uses set it.
    @_spi(Testing) public static func sdkFeatures() -> [String: Bool] {
      SentryReporter.features(dsn: "https://public@example.invalid/1", environment: "test", diagnosticsID: "id")
    }
  }
#endif
