import UserNotifications
import WishboneAPI
import WishboneSession

/// The system's notification center, where the app schedules its reminders. Only the app gives it: the extensions
/// never schedule. See "Staying correct" in `docs/spec.md`, and "Where the other pieces live" in
/// `docs/architecture.md`.
///
/// The app schedules only reminders, so it removes every request of the app's.
nonisolated struct SystemReminderCenter: ReminderCenter {
  private var center: UNUserNotificationCenter { .current() }

  func authorization() async -> ReminderAuthorization {
    switch await center.notificationSettings().authorizationStatus {
    case .notDetermined: .notDetermined
    case .denied: .denied
    case .provisional: .provisional
    case .authorized, .ephemeral: .authorized
    @unknown default: .denied
    }
  }

  func requestProvisionalAuthorization() async {
    do {
      // Provisional: iOS shows no alert, delivers quietly to Notification Center, and offers Keep or Turn Off on the
      // first reminder. No badge: nothing sets one.
      _ = try await center.requestAuthorization(options: [.provisional, .alert])
    } catch {
      // It is no fault of the app, and diagnostics never hear of it. The reminders wait for an answer.
      Log.notice(.session, "Provisional authorization for reminders can't be asked.", detail: "\(error)")
    }
  }

  func replacePending(with requests: [ReminderRequest]) async {
    center.removeAllPendingNotificationRequests()
    for request in requests {
      do {
        try await center.add(request.notificationRequest)
      } catch {
        Log.notice(.session, "A reminder can't be scheduled.", detail: "\(error)")
      }
    }
  }

  func removeAll() {
    center.removeAllPendingNotificationRequests()
    center.removeAllDeliveredNotifications()
  }
}
