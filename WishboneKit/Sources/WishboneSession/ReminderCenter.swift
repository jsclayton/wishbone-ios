import Foundation
import UserNotifications
import WishboneAPI

/// What iOS lets the app do with its reminders.
public enum ReminderAuthorization: Sendable, Equatable {
  /// The app has not asked yet.
  case notDetermined

  /// Notifications are off for the app in iOS. The app never asks again.
  case denied

  /// Provisional: reminders arrive quietly in Notification Center, and iOS offers Keep or Turn Off on the first one.
  case provisional

  /// Full: reminders show on the Lock Screen too.
  case authorized

  /// Whether a reminder that the app schedules is delivered.
  var delivers: Bool {
    self == .provisional || self == .authorized
  }
}

/// A reminder as the app hands it to iOS: its identifier, its words, and its one date trigger. These are all its
/// fields, and the secrecy suite holds them to an allow list. See "The rule for system surfaces" in `docs/spec.md`.
public struct ReminderRequest: Sendable, Equatable {
  /// The reminder's identifier, as text. See `ReminderIdentifier`.
  public let identifier: String

  /// The title, "Wishbone".
  public let title: String

  /// The one line that names the occasion and the person, and when it is.
  public let body: String

  /// The day and the time that the trigger matches: the year, the month, the day, the hour and the minute, with no
  /// time zone, so it fires in the device's zone.
  public let fires: DateComponents

  /// Whether the trigger repeats. Never: a reminder fires once, so none outlives the data it came from.
  public let repeats: Bool

  /// The request for a reminder of the plan, with its words.
  public init(_ reminder: PlannedReminder, words: ReminderWords) {
    identifier = reminder.identifier.description
    title = words.title()
    body = words.body(reminder.phrase)
    fires = reminder.fires
    repeats = false
  }

  /// The request as the notification center takes it. Its content has a title and a body, and nothing more: no
  /// badge, no sound, no user info, no attachment, and no category, so it has no action buttons.
  public var notificationRequest: UNNotificationRequest {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    let trigger = UNCalendarNotificationTrigger(dateMatching: fires, repeats: repeats)
    return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
  }
}

/// The words of the reminders, from the String Catalog in `WishboneUI`. The app gives the catalog's. See "Which
/// occasions" in `docs/spec.md`, and `docs/screens/reminder.md`.
public struct ReminderWords: Sendable {
  /// The title of every reminder.
  public let title: @Sendable () -> String

  /// The one line of a reminder.
  public let body: @Sendable (ReminderPhrase) -> String

  public init(title: @escaping @Sendable () -> String, body: @escaping @Sendable (ReminderPhrase) -> String) {
    self.title = title
    self.body = body
  }

  /// No words: the words of a device that schedules nothing, such as an extension's.
  public static let none = ReminderWords(title: { "" }, body: { _ in "" })
}

/// The notification center, as the session schedules its reminders there. See "Staying correct" in `docs/spec.md`.
///
/// Only the app gives the system's, through `UNUserNotificationCenter`. An extension gives none, so it never
/// schedules.
public protocol ReminderCenter: Sendable {
  /// What iOS lets the app do now.
  func authorization() async -> ReminderAuthorization

  /// Asks iOS for provisional authorization. iOS shows no alert.
  func requestProvisionalAuthorization() async

  /// Removes every pending reminder, then schedules these.
  func replacePending(with requests: [ReminderRequest]) async

  /// Removes every reminder: the pending ones, and the ones in Notification Center.
  func removeAll()
}

/// No reminders: the center of the extensions, and of the tests that don't check it.
public struct NoReminderCenter: ReminderCenter {
  public init() {}
  public func authorization() async -> ReminderAuthorization { .denied }
  public func requestProvisionalAuthorization() async {}
  public func replacePending(with requests: [ReminderRequest]) async {}
  public func removeAll() {}
}

extension ReminderCenter where Self == NoReminderCenter {
  /// No reminders.
  public static var none: NoReminderCenter { NoReminderCenter() }
}
