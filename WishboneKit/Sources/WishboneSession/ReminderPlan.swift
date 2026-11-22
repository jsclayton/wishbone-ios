import Foundation
import WishboneAPI

/// The reminder settings: one switch for every occasion, and the timing. See "One switch, and the timing" in
/// `docs/spec.md`. They belong to the session: the session keeps them in a file of its own (see
/// `ReminderSettingsFile`), and they go at sign-out.
public struct ReminderSettings: Sendable, Equatable, Codable {
  /// Whether the app schedules reminders at all. On by default.
  public var isOn: Bool

  /// How long before an occasion the early reminder comes. Two weeks by default.
  public var early: EarlyReminder

  /// Whether a reminder comes on the day of the occasion too. On by default.
  public var onTheDay: Bool

  public init(isOn: Bool = true, early: EarlyReminder = .twoWeeks, onTheDay: Bool = true) {
    self.isOn = isOn
    self.early = early
    self.onTheDay = onTheDay
  }
}

/// How long before an occasion the early reminder comes. The user picks one of the three.
public enum EarlyReminder: Int, Sendable, Equatable, CaseIterable, Codable {
  case oneWeek = 1
  case twoWeeks = 2
  case fourWeeks = 4

  /// How many days before the occasion.
  var days: Int { rawValue * 7 }
}

/// Which of an occasion's two reminders.
public enum ReminderKind: String, Sendable, Equatable, CaseIterable {
  /// The early one: 1, 2, or 4 weeks before.
  case early

  /// The one on the day.
  case onTheDay = "day"
}

/// Whose occasion a reminder names, and how. It holds only the occasion and the person: never a list, an item, a
/// gift, or the instance. See "The rule for system surfaces" in `docs/spec.md`.
public enum ReminderSubject: Sendable, Equatable {
  /// Someone else's birthday, by the person's name.
  case birthday(person: String)

  /// Someone else's custom occasion, by the person's name and the occasion's.
  case custom(person: String, occasion: String)

  /// A shared occasion, by its name.
  case shared(occasion: String)

  /// The session's user's own birthday.
  case ownBirthday

  /// The session's user's own custom occasion, by its name.
  case ownCustom(occasion: String)
}

/// What a reminder says, before it has words: whose occasion, which reminder, and for the early one, how early.
/// The words come from the String Catalog, in `WishboneUI` (see `ReminderWords`).
public struct ReminderPhrase: Sendable, Equatable {
  public let subject: ReminderSubject

  /// How early the reminder comes. Nil for the one on the day.
  public let early: EarlyReminder?

  public init(subject: ReminderSubject, early: EarlyReminder?) {
    self.subject = subject
    self.early = early
  }
}

/// The identifier of a reminder: the instance, the user, the occasion, and which reminder it is. A tap compares it
/// with the session that the device holds. See "Staying correct" in `docs/spec.md`.
///
/// As text, it is `reminder|{kind}|{occasion}|{user}|{instance}`. The instance's address comes last, so any
/// character in it reads back.
public struct ReminderIdentifier: Sendable, Equatable, CustomStringConvertible {
  public let instance: InstanceAddress
  public let userID: String
  public let occasionID: String
  public let kind: ReminderKind

  public init(instance: InstanceAddress, userID: String, occasionID: String, kind: ReminderKind) {
    self.instance = instance
    self.userID = userID
    self.occasionID = occasionID
    self.kind = kind
  }

  /// What every reminder's identifier starts with.
  static let prefix = "reminder"

  /// The identifier as the notification request carries it.
  public var description: String {
    [Self.prefix, kind.rawValue, occasionID, userID, instance.text].joined(separator: "|")
  }

  /// Reads an identifier back. Nil for text that is not a reminder's identifier.
  public init?(_ text: String) {
    let parts = text.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 5, parts[0] == Self.prefix, let kind = ReminderKind(rawValue: parts[1]),
      !parts[2].isEmpty, !parts[3].isEmpty, let instance = InstanceAddress(parts[4])
    else { return nil }
    self.init(instance: instance, userID: parts[3], occasionID: parts[2], kind: kind)
  }
}

/// One reminder of the plan: when it fires, and what it says.
public struct PlannedReminder: Sendable, Equatable {
  public let identifier: ReminderIdentifier
  public let phrase: ReminderPhrase

  /// The day and the time it fires, as a date trigger matches them: the year, the month, the day, 9 as the hour, and
  /// 0 as the minute. It names no time zone, so it fires at 9:00 in the zone that the device has then.
  public let fires: DateComponents

  /// When it fires, in the zone that the plan was made in. The plan orders by it.
  let fireDate: Date
}

/// The reminder plan: occasions, settings, and a clock go in, and the reminders come out. It is pure. See "Staying
/// correct" in `docs/spec.md`, and "Where the other pieces live" in `docs/architecture.md`.
public enum ReminderPlan {
  /// An occasion, as the plan reads it from the copy.
  public struct Occasion: Sendable, Equatable {
    public let id: String
    public let kind: OccasionKind
    public let name: String

    /// The user that the occasion is for. Nil for a shared occasion.
    public let userID: String?

    /// The first date of the occasion that is today or later, as `YYYY-MM-DD`, in the occasion's own zone. Nil when
    /// none is left.
    public let nextDate: String?

    public init(id: String, kind: OccasionKind, name: String, userID: String?, nextDate: String?) {
      self.id = id
      self.kind = kind
      self.name = name
      self.userID = userID
      self.nextDate = nextDate
    }

    init(_ row: OccasionRow) {
      self.init(id: row.id, kind: row.kind, name: row.name, userID: row.userID, nextDate: row.nextDate)
    }
  }

  /// Only the occasions in the next 60 days.
  public static let days = 60

  /// At most the 60 soonest reminders. iOS has long kept 64 pending local notifications for each app.
  public static let limit = 60

  /// The hour of the day that every reminder fires at, in the device's zone. It is fixed in the first release.
  public static let hour = 9

  /// The reminders for the occasions: two for each occasion in the next 60 days, the early one and the one on the
  /// day, both at 9:00 in the device's zone. A reminder whose time has passed is left out, and so are the ones
  /// after the 60 soonest.
  ///
  /// - Parameters:
  ///   - occasions: every occasion that the session's user can see, as the copy holds them.
  ///   - names: the name of each user in the copy, by ID. An occasion of a user with no name here gets none.
  ///   - session: the instance and the user that the identifiers carry. The user's own occasions say "Your".
  ///   - now: the time now.
  ///   - timeZone: the device's zone. `next_date` is a date in the occasion's own zone, and the reminder fires at
  ///     9:00 on that date, in the device's zone.
  public static func reminders(
    for occasions: [Occasion],
    names: [String: String],
    session: Session,
    settings: ReminderSettings,
    now: Date,
    timeZone: TimeZone
  ) -> [PlannedReminder] {
    guard settings.isOn else { return [] }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let today = calendar.startOfDay(for: now)
    guard let last = calendar.date(byAdding: .day, value: days, to: today) else { return [] }

    var reminders: [PlannedReminder] = []
    for occasion in occasions {
      guard let date = occasion.nextDate.flatMap({ day(of: $0, in: calendar) }), date >= today, date <= last,
        let subject = subject(of: occasion, names: names, userID: session.userID)
      else { continue }
      var timings: [(ReminderKind, offset: Int, early: EarlyReminder?)] = []
      timings.append((.early, settings.early.days, settings.early))
      if settings.onTheDay { timings.append((.onTheDay, 0, nil)) }
      for (kind, offset, early) in timings {
        guard let day = calendar.date(byAdding: .day, value: -offset, to: date),
          let fireDate = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day),
          fireDate > now
        else { continue }
        var fires = calendar.dateComponents([.year, .month, .day], from: day)
        fires.hour = hour
        fires.minute = 0
        let identifier = ReminderIdentifier(
          instance: session.instance, userID: session.userID, occasionID: occasion.id, kind: kind)
        reminders.append(
          PlannedReminder(
            identifier: identifier, phrase: ReminderPhrase(subject: subject, early: early), fires: fires,
            fireDate: fireDate))
      }
    }
    // The soonest first. Two at the same time go by their identifiers, so the cut is the same each time.
    reminders.sort { first, second in
      first.fireDate != second.fireDate
        ? first.fireDate < second.fireDate : first.identifier.description < second.identifier.description
    }
    return Array(reminders.prefix(limit))
  }

  /// The start of the day of a `YYYY-MM-DD` date, in the calendar's zone. Nil for text that is not such a date.
  private static func day(of text: String, in calendar: Calendar) -> Date? {
    let parts = text.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
    guard components.isValidDate(in: calendar) else { return nil }
    return calendar.date(from: components)
  }

  /// Whose occasion it is, for the words. Nil for an occasion that the app can't name: a kind that it doesn't know,
  /// or a user with no name in the copy.
  private static func subject(of occasion: Occasion, names: [String: String], userID: String) -> ReminderSubject? {
    let isOwn = occasion.userID == userID
    switch occasion.kind {
    case .shared:
      return .shared(occasion: occasion.name)
    case .birthday:
      if isOwn { return .ownBirthday }
      return occasion.userID.flatMap { names[$0] }.map { .birthday(person: $0) }
    case .custom:
      if isOwn { return .ownCustom(occasion: occasion.name) }
      return occasion.userID.flatMap { names[$0] }.map { .custom(person: $0, occasion: occasion.name) }
    case .unknown:
      return nil
    }
  }
}
