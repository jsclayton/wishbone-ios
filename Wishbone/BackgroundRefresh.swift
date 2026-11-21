import BackgroundTasks
import Foundation
import WishboneAPI
import WishboneSession

/// Background app refresh, which only the app registers and schedules. The extensions never do. See "When the app
/// syncs" in `docs/spec.md`, and "Where the other pieces live" in `docs/architecture.md`.
nonisolated enum BackgroundRefresh {
  /// The identifier of the app's one refresh task: the app's bundle identifier and `.refresh`. The app's
  /// `Info.plist` permits it in `BGTaskSchedulerPermittedIdentifiers`, and a hosted test holds the two equal.
  static let identifier = "\(Bundle.main.bundleIdentifier ?? "").refresh"
}

/// The system's scheduler of background refresh, through `BGTaskScheduler`. iOS decides when a request runs, if
/// ever: never while Background App Refresh is off, or in Low Power Mode, or in the simulator.
nonisolated struct SystemRefreshScheduler: RefreshScheduler {
  func requestRefresh(after delay: Duration) {
    let request = BGAppRefreshTaskRequest(identifier: BackgroundRefresh.identifier)
    request.earliestBeginDate = .now.addingTimeInterval(TimeInterval(delay.components.seconds))
    // A request takes the place of the one that is pending, which has the same identifier.
    BGTaskScheduler.shared.submitTaskRequest(request) { error in
      // Background App Refresh is off, or the simulator has none. It is no fault of the app, and diagnostics never
      // hear of it. The next time the app goes to the background, it asks again.
      if let error { Log.notice(.session, "The background refresh can't be scheduled.", detail: "\(error)") }
    }
  }

  func cancelRefresh() {
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundRefresh.identifier)
  }
}
