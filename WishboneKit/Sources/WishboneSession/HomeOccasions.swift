import Foundation
import WishboneAPI

// Home's occasions: the countdown and Coming up. See "Home" in `docs/spec.md`, `docs/screens/home.md`, and the
// server spec's "Home".
//
// The countdown and Coming up are pure: the occasions, the people, the user's open gifts, and the day go in, and
// what Home shows comes out. The session model reads them from the copy (see `SessionModel.homeOccasions(today:)`).

/// One occasion as Home shows it: in the countdown, and in Coming up.
public struct HomeOccasion: Equatable, Sendable, Identifiable {
  /// Whose occasion it is, for its words and its color.
  public enum Whose: Equatable, Sendable {
    /// Someone else's birthday or custom occasion, by the person's ID and name.
    case person(id: String, name: String)

    /// The session's user's own birthday or custom occasion.
    case own

    /// A shared occasion. `isEveryone` says that it is for every user.
    case shared(isEveryone: Bool)
  }

  /// What a tap on the occasion opens. See "How each thing is reached" in `docs/spec.md`.
  public enum Destination: Equatable, Sendable {
    /// A person's occasion opens that person's page.
    case user(id: String)

    /// The user's own occasion opens their primary list.
    case list(id: String)

    /// A shared occasion opens its page.
    case sharedOccasion(id: String)
  }

  /// The user's own open gifts for the occasion, on its next date.
  public struct Gifts: Equatable, Sendable {
    /// How many gifts the user has for it: "{n} from you".
    public let fromYou: Int

    /// How many of those are not bought yet: "{m} still to buy".
    public let toBuy: Int

    public init(fromYou: Int, toBuy: Int) {
      self.fromYou = fromYou
      self.toBuy = toBuy
    }
  }

  /// The occasion's ID.
  public let id: String
  public let kind: OccasionKind

  /// The occasion's own name. A birthday's is always "Birthday": its words come from the kind.
  public let name: String
  public let whose: Whose

  /// The occasion's next date, as `YYYY-MM-DD`.
  public let date: String

  /// How many days from today, in the device's zone, to the date: 0 is today.
  public let daysLeft: Int

  /// The time left, as the words say it: "today", "tomorrow", or "in {n} days".
  public enum TimeLeft: Equatable, Sendable {
    case today
    case tomorrow
    case days(Int)
  }

  public var timeLeft: TimeLeft {
    switch daysLeft {
    case ...0: .today
    case 1: .tomorrow
    default: .days(daysLeft)
    }
  }

  /// For a birthday whose year the user sees: the age that the person turns on the date. Nil otherwise.
  public let turning: Int?

  public let gifts: Gifts

  /// What a tap opens. Nil for the user's own occasion while the copy has no primary list for them.
  public let destination: Destination?
}

/// What Home shows of the occasions.
public struct HomeOccasions: Equatable, Sendable {
  /// The countdown: the next occasion in the next 60 days that is not the user's own. When two are on that day, it
  /// has both. Empty when there is none: the countdown says so.
  public let countdown: [HomeOccasion]

  /// Coming up: every occasion in the next 60 days, the user's own included, the soonest first. Empty shows its
  /// empty line.
  public let comingUp: [HomeOccasion]

  /// Only the occasions in the next 60 days.
  public static let days = 60

  /// An occasion, as Home reads it from the copy.
  public struct Occasion: Sendable, Equatable {
    public let id: String
    public let kind: OccasionKind
    public let name: String

    /// The user that the occasion is for. Nil for a shared occasion.
    public let userID: String?

    /// For a shared occasion: whether it is for every user.
    public let isEveryone: Bool

    /// The first date of the occasion that is today or later, as `YYYY-MM-DD`, in the occasion's own zone. Nil
    /// when none is left.
    public let nextDate: String?

    public init(
      id: String, kind: OccasionKind, name: String, userID: String?, isEveryone: Bool = false, nextDate: String?
    ) {
      self.id = id
      self.kind = kind
      self.name = name
      self.userID = userID
      self.isEveryone = isEveryone
      self.nextDate = nextDate
    }
  }

  /// A person whose occasion Home can show.
  public struct Person: Sendable, Equatable {
    public let name: String

    /// The year of their birthday, when the session's user sees it.
    public let birthYear: Int?

    /// Their primary list, when the session's user can see it.
    public let primaryListID: String?

    public init(name: String, birthYear: Int? = nil, primaryListID: String? = nil) {
      self.name = name
      self.birthYear = birthYear
      self.primaryListID = primaryListID
    }
  }

  /// One of the session's user's own open gifts, as the counts read it.
  public struct Gift: Sendable, Equatable {
    /// The gift's occasion. Nil when the giver can't see it.
    public let occasionID: String?

    /// The date the occasion fell on when the giver picked it, as `YYYY-MM-DD`.
    public let occasionDate: String
    public let isBought: Bool

    public init(occasionID: String?, occasionDate: String, isBought: Bool) {
      self.occasionID = occasionID
      self.occasionDate = occasionDate
      self.isBought = isBought
    }
  }

  public init(countdown: [HomeOccasion], comingUp: [HomeOccasion]) {
    self.countdown = countdown
    self.comingUp = comingUp
  }

  /// Home's occasions.
  ///
  /// - Coming up has every occasion with a next date from today to 60 days after, in the device's zone, soonest
  ///   first. Each occasion is one row: a shared occasion too. One whose person is not in the copy, or whose kind
  ///   the app doesn't know, is left out, as the reminders leave it out.
  /// - The countdown has the soonest of those that is not the user's own birthday or custom occasion, and every
  ///   other one on the same day.
  /// - The gift counts are the user's own open gifts for the occasion on its next date: "the user's own open gifts
  ///   for that user on the occasion's date", as the server spec counts them.
  ///
  /// - Parameters:
  ///   - occasions: every occasion that the session's user can see.
  ///   - people: the people of the copy, by ID.
  ///   - me: the session's user. Their own person gives their primary list.
  ///   - gifts: the session's user's own open gifts.
  ///   - today: a time in the day to count from.
  ///   - timeZone: the device's zone. "today" changes at its midnight.
  public init(
    occasions: [Occasion],
    people: [String: Person],
    me: String,
    gifts: [Gift],
    today: Date,
    timeZone: TimeZone
  ) {
    let comingUp = Self.rows(
      occasions: occasions, people: people, me: me, gifts: gifts, today: today, timeZone: timeZone, within: Self.days)
    let others = comingUp.filter { $0.whose != .own }
    let soonest = others.first?.daysLeft
    self.init(countdown: others.filter { $0.daysLeft == soonest }, comingUp: comingUp)
  }

  /// The occasions as rows, soonest first: every occasion with a next date from today on, in the device's zone, and
  /// with `days`, only the ones up to that many days after today. Each occasion is one row: a shared occasion too.
  /// One whose person is not in the copy, or whose kind the app doesn't know, is left out, as the reminders leave
  /// it out.
  ///
  /// The gift counts are the user's own open gifts for the occasion on its next date.
  public static func rows(
    occasions: [Occasion],
    people: [String: Person],
    me: String,
    gifts: [Gift],
    today: Date,
    timeZone: TimeZone,
    within days: Int?
  ) -> [HomeOccasion] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let start = calendar.startOfDay(for: today)

    var rows: [HomeOccasion] = []
    for occasion in occasions {
      guard let text = occasion.nextDate, let date = day(of: text, in: calendar),
        let daysLeft = calendar.dateComponents([.day], from: start, to: date).day,
        daysLeft >= 0, days.map({ daysLeft <= $0 }) ?? true
      else { continue }

      let whose: HomeOccasion.Whose
      let destination: HomeOccasion.Destination?
      var turning: Int?
      switch occasion.kind {
      case .shared:
        whose = .shared(isEveryone: occasion.isEveryone)
        destination = .sharedOccasion(id: occasion.id)
      case .birthday, .custom:
        guard let userID = occasion.userID else { continue }
        if userID == me {
          whose = .own
          destination = people[me]?.primaryListID.map { .list(id: $0) }
        } else {
          guard let person = people[userID] else { continue }
          whose = .person(id: userID, name: person.name)
          destination = .user(id: userID)
        }
        if occasion.kind == .birthday, let year = people[userID]?.birthYear,
          let dateYear = calendar.dateComponents([.year], from: date).year
        {
          turning = dateYear - year
        }
      case .unknown:
        continue
      }

      let own = gifts.filter { $0.occasionID == occasion.id && $0.occasionDate == text }
      rows.append(
        HomeOccasion(
          id: occasion.id, kind: occasion.kind, name: occasion.name, whose: whose, date: text, daysLeft: daysLeft,
          turning: turning,
          gifts: HomeOccasion.Gifts(fromYou: own.count, toBuy: own.count { !$0.isBought }),
          destination: destination))
    }
    // The soonest first. Two on one day keep the order they came in: the copy's, by name.
    return rows.enumerated().sorted { first, second in
      first.element.daysLeft != second.element.daysLeft
        ? first.element.daysLeft < second.element.daysLeft : first.offset < second.offset
    }.map(\.element)
  }

  /// The start of the day of a `YYYY-MM-DD` date, in the calendar's zone. Nil for text that is not such a date.
  static func day(of text: String, in calendar: Calendar) -> Date? {
    let parts = text.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
    guard components.isValidDate(in: calendar) else { return nil }
    return calendar.date(from: components)
  }
}

extension SessionModel {
  /// Home's occasions, from the copy, for the day of `today` in the device's zone.
  public func homeOccasions(today: Date = .now) -> HomeOccasions {
    let inputs = occasionInputs()
    return HomeOccasions(
      occasions: inputs.occasions, people: inputs.people, me: session.userID, gifts: inputs.gifts, today: today,
      timeZone: deviceTimeZone)
  }

  /// The Occasions screen's Coming up, from the copy: every occasion that has a next date, from the day of `today`
  /// in the device's zone, soonest first, the user's own included. See `docs/screens/occasions.md`.
  public func everyOccasion(today: Date = .now) -> [HomeOccasion] {
    let inputs = occasionInputs()
    return HomeOccasions.rows(
      occasions: inputs.occasions, people: inputs.people, me: session.userID, gifts: inputs.gifts, today: today,
      timeZone: deviceTimeZone, within: nil)
  }

  /// The device's zone, as the session model knows it.
  var deviceTimeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .gmt }

  /// The occasions, the people, and the user's own open gifts, from the copy, as the occasions' rows read them.
  private func occasionInputs() -> (
    occasions: [HomeOccasions.Occasion], people: [String: HomeOccasions.Person], gifts: [HomeOccasions.Gift]
  ) {
    var people: [String: HomeOccasions.Person] = [:]
    for user in users {
      people[user.id] = HomeOccasions.Person(
        name: user.name, birthYear: user.record?.birthday.year, primaryListID: user.record?.primaryListID)
    }
    let occasions = occasions.map { row in
      HomeOccasions.Occasion(
        id: row.id, kind: row.kind, name: row.name, userID: row.userID, isEveryone: row.isEveryone ?? false,
        nextDate: row.nextDate)
    }
    let gifts = giving.map { gift in
      HomeOccasions.Gift(
        occasionID: gift.occasion?.id, occasionDate: gift.occasionDate, isBought: gift.isBought.value ?? false)
    }
    return (occasions, people, gifts)
  }
}
