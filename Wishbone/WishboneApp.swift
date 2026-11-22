import SwiftUI
import WishboneAPI
import WishboneDiagnostics
import WishboneSession
import WishboneUI

@main
struct WishboneApp: App {
  /// The one device of the app. Every window scene reads it from the environment.
  @State private var device: Device

  /// The device's diagnostics. They start here at launch, when the rule allows: the notice was shown at an earlier
  /// launch, the switch is on, and the build has a DSN. See "On by default, for each device, after a notice" in
  /// `docs/spec.md`.
  @State private var diagnostics: DiagnosticsSettings

  /// The phase of the app as a whole: `.background` once no window is in the foreground.
  @Environment(\.scenePhase) private var phase

  init() {
    let diagnostics = Diagnostics.app()
    diagnostics.start()
    _diagnostics = State(initialValue: DiagnosticsSettings(diagnostics))
    // The device reports the app's own faults, and each request, to diagnostics.
    _device = State(initialValue: Device(.app(diagnostics: diagnostics.reporter)))
  }

  var body: some Scene {
    WindowGroup {
      WindowRoot()
        .environment(device)
        .environment(\.diagnostics, diagnostics)
        .environment(\.diagnosticsReporter, diagnostics.reporter)
        .modifier(ScenePhaseBreadcrumbs(diagnostics: diagnostics.reporter))
        #if DEBUG
          .task { await Journey.pasteLoginLink(into: device) }
        #endif
    }
    // Each time the app goes to the background, it asks iOS for the next background refresh.
    .onChange(of: phase) { _, phase in
      if phase == .background { device.wentToBackground() }
    }
    // A background refresh: one sync, after which the session asks for the next. When iOS ends the run early, it
    // cancels this task, and the sync stops.
    .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) { [device] in
      _ = await device.refreshInBackground()
    }
  }
}

/// Leaves a breadcrumb for each change of the window scene's phase. Each window has its own phase.
private struct ScenePhaseBreadcrumbs: ViewModifier {
  let diagnostics: any DiagnosticsReporter
  @Environment(\.scenePhase) private var scenePhase

  func body(content: Content) -> some View {
    content.onChange(of: scenePhase) { _, phase in
      switch phase {
      case .active: diagnostics.leave(.scenePhase(.active))
      case .inactive: diagnostics.leave(.scenePhase(.inactive))
      case .background: diagnostics.leave(.scenePhase(.background))
      @unknown default: break
      }
    }
  }
}

/// The diagnostics switch that the screens see. `WishboneUI` can't import `WishboneDiagnostics`, because the share
/// extension links `WishboneUI`, so the app joins the two.
final class DiagnosticsSettings: DiagnosticsSwitch {
  private let diagnostics: Diagnostics

  init(_ diagnostics: Diagnostics) {
    self.diagnostics = diagnostics
  }

  /// Where the app's own faults and breadcrumbs go.
  nonisolated var reporter: any DiagnosticsReporter {
    diagnostics.reporter
  }

  var isOn: Bool {
    get { diagnostics.isOn }
    set { diagnostics.isOn = newValue }
  }

  func noticeShown() {
    diagnostics.noticeShown()
  }
}

extension Device.Setup {
  /// What the app gives its device: the session keychain in the shared access group, the install marker in the app
  /// group's shared container, the database in the app's own Application Support folder, diagnostics, and the
  /// system's notification center for the reminders, with the String Catalog's words.
  static func app(diagnostics: any DiagnosticsReporter) -> Device.Setup {
    let info = Bundle.main
    let version = info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    let accessGroup = info.object(forInfoDictionaryKey: "WishboneKeychainAccessGroup") as? String ?? ""
    let appGroup = info.object(forInfoDictionaryKey: "WishboneAppGroup") as? String ?? ""
    #if DEBUG
      Journey.startSignedOut(accessGroup: accessGroup)
    #endif
    return Device.Setup(
      userAgent: UserAgent(version: version, isPad: UIDevice.current.userInterfaceIdiom == .pad),
      keychain: SystemSessionKeychain(accessGroup: accessGroup),
      marker: installMarker(appGroup: appGroup),
      storage: .folder(.applicationSupportDirectory),
      // The images come from the instance again, so they go in the app's own Caches folder, never the shared
      // container.
      images: .folder(.cachesDirectory),
      network: .system,
      refresh: SystemRefreshScheduler(),
      diagnostics: diagnostics,
      reminders: Reminders(center: SystemReminderCenter(), words: .catalog)
    )
  }

  /// The install marker in the app group's shared container. A build with no app group, which is a fault, keeps
  /// the marker in the app's own Application Support folder: deleting the app deletes that folder too, so the app
  /// still starts signed out after a reinstall.
  private static func installMarker(appGroup: String) -> FileInstallMarker {
    if let marker = FileInstallMarker(appGroup: appGroup) { return marker }
    Log.fault(.session, "The app group's shared container is missing.")
    return FileInstallMarker(container: .applicationSupportDirectory)
  }
}
