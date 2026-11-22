import Foundation
import WishboneAPI

/// What a device gives its sessions for their reminders: the notification center, the words, and the clock of the
/// plan. The default schedules nothing: only the app gives the system's center and the catalog's words.
public struct Reminders: Sendable {
  public var center: any ReminderCenter
  public var words: ReminderWords

  /// The time now, which the plan starts from.
  public var now: @Sendable () -> Date

  public init(
    center: any ReminderCenter = .none,
    words: ReminderWords = .none,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.center = center
    self.words = words
    self.now = now
  }

  /// No reminders: the reminders of an extension, and of the tests that don't check them.
  public static let none = Reminders()
}

extension SessionModel {
  /// Rebuilds the whole set of reminders from the copy: it removes every pending reminder, then schedules the
  /// plan's. See "Staying correct" in `docs/spec.md`.
  ///
  /// It runs after every sync that succeeded, and after the profile gate. A failed sync leaves the set as it is. One
  /// rebuild runs at a time: a call during one runs after it.
  ///
  /// Before the first rebuild after sign-in and the profile gate, it asks iOS for provisional authorization, once:
  /// while iOS has no answer from the user. After that iOS has one, so the app never asks again. While the gate
  /// shows, it doesn't ask. See "Turning them on" in `docs/spec.md`.
  ///
  /// Nothing is scheduled while notifications are off for the app, or reminders are off in the app.
  ///
  /// Diagnostics: never. A copy that can't be read is logged, and leaves the set as it is.
  func rebuildReminders() async {
    let previous = rebuildingReminders
    let task = Task {
      await previous?.value
      await rebuildRemindersNow()
    }
    rebuildingReminders = task
    await task.value
  }

  private func rebuildRemindersNow() async {
    guard !hasEnded else { return }
    let sources: LocalDatabase.ReminderSources
    do {
      sources = try await database.reminderSources(ofUser: session.userID)
    } catch is CancellationError {
      return
    } catch {
      Log.fault(.session, "The copy can't be read for the reminders.", detail: "\(error)")
      return
    }
    let center = reminders.center
    let settings = reminderSettings
    var authorization = await center.authorization()
    if authorization == .notDetermined, settings.isOn, sources.needsProfileGate == false, !hasEnded {
      await center.requestProvisionalAuthorization()
      authorization = await center.authorization()
    }
    let requests: [ReminderRequest]
    if authorization.delivers {
      let plan = ReminderPlan.reminders(
        for: sources.occasions.map(ReminderPlan.Occasion.init), names: sources.names, session: session,
        settings: settings,
        now: reminders.now(), timeZone: TimeZone(identifier: timeZoneIdentifier) ?? .current)
      requests = plan.map { ReminderRequest($0, words: reminders.words) }
    } else {
      requests = []
    }
    // A sign-out during the rebuild removes every reminder after it, so it schedules none.
    guard !hasEnded else { return }
    await center.replacePending(with: requests)
  }
}
