import Foundation
import Observation

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
  public private(set) var isRunning = false

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
  }

  /// Reads the switch from `defaults`. It doesn't start the SDK: ``start()`` does.
  ///
  /// `folder` is where the SDK keeps what it has not sent yet: reports, and crashes from an earlier run.
  public init(build: Build, defaults: UserDefaults, folder: URL) {
    self.build = build
    self.defaults = defaults
    self.folder = folder
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
    SentryReporter.start(dsn: build.dsn, environment: build.environment, diagnosticsID: id, folder: folder)
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
    // What is on disk goes first, so the SDK can't send it while it closes. Then once more, for what it wrote then.
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

#if DEBUG
  extension Diagnostics {
    /// For the tests only: sends a fixed probe event, with no words of its own, through the running SDK.
    @_spi(Testing) public func sendProbe() {
      guard isRunning else { return }
      SentryReporter.sendProbe()
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
