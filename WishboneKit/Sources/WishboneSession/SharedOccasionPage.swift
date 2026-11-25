import Foundation
import WishboneAPI

// A shared occasion's page, from the copy: its name, its date and the days left, who it reaches, and the users it
// applies to whom the session's user can see, each with the user's own open gifts for them. The page is the same
// for everyone: only the admin also gets the names of its groups, because the server gives them to nobody else.
// See "Shared occasions" in `docs/spec.md`, and `docs/screens/occasions.md`.
//
// **The counts are the giver's own.** Each is the session's user's own open gifts for that user on this occasion.
// They stay inside the app: a reminder and the widget show the occasion with no counts.

/// What a shared occasion's page shows. The session model builds it from the copy: see
/// `SessionModel.sharedOccasionPage(id:today:)`.
public struct SharedOccasionPage: Equatable, Sendable {
  /// The occasion's ID.
  public let id: String
  public let name: String

  /// The occasion's next date, as `YYYY-MM-DD`. Nil when none is left.
  public let date: String?

  /// How many days from today, in the device's zone, to the date: 0 is today. Nil with no date, and for a date that
  /// is already past in the device's zone, as Home counts it.
  public let daysLeft: Int?

  /// The time left, as the words say it. Nil with no date.
  public var timeLeft: HomeOccasion.TimeLeft? {
    daysLeft.map { days in
      switch days {
      case ...0: .today
      case 1: .tomorrow
      default: .days(days)
      }
    }
  }

  /// Whether the occasion is for every user: the page says "Everyone".
  public let isEveryone: Bool

  /// The names of the groups that the occasion is attached to, by name. Only the admin's copy has them, so for
  /// anyone else this is empty.
  public let groupNames: [String]

  /// The users that the occasion applies to whom the session's user can see, in the server's order, never the
  /// session's user, as the web leaves them out. Empty says that it reaches nobody else the user sees. Nil says
  /// that the copy doesn't have them yet: the page says nothing about them until the next sync brings them.
  public let people: [Person]?

  /// A user on the occasion, with the session's user's own open gifts for them on it.
  public struct Person: Equatable, Sendable, Identifiable {
    public let user: UserRow

    /// How many open gifts the session's user has for this user on this occasion: "{n} from you", or "Nothing yet"
    /// for 0.
    public let fromYou: Int

    public var id: String { user.id }

    public init(user: UserRow, fromYou: Int) {
      self.user = user
      self.fromYou = fromYou
    }
  }
}

extension SharedOccasionPage {
  /// One of the user's open gifts, as the page counts it.
  public struct Gift: Sendable, Equatable {
    /// The gift's occasion. Nil when the giver can't see it.
    public let occasionID: String?

    /// The date the occasion fell on when the giver picked it, as `YYYY-MM-DD`.
    public let occasionDate: String

    /// The users the gift is for. Empty when they are hidden.
    public let recipientIDs: [String]

    public init(occasionID: String?, occasionDate: String, recipientIDs: [String]) {
      self.occasionID = occasionID
      self.occasionDate = occasionDate
      self.recipientIDs = recipientIDs
    }
  }

  /// A user on the occasion by ID, with how many of the user's open gifts are for them on it.
  public struct Count: Sendable, Equatable {
    public let id: String
    public let fromYou: Int

    public init(id: String, fromYou: Int) {
      self.id = id
      self.fromYou = fromYou
    }
  }

  /// How many days from today to the next date, in the device's zone, by Home's rule: 0 is today. Nil with no date,
  /// and for a date that is already past in the device's zone, which Home's countdown leaves out too. The next date
  /// is in the occasion's own zone, so in a zone ahead of it, it can be yesterday.
  public static func daysLeft(until nextDate: String?, today: Date, timeZone: TimeZone) -> Int? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    guard let nextDate, let date = HomeOccasions.day(of: nextDate, in: calendar) else { return nil }
    return HomeOccasions.daysLeft(until: date, from: calendar.startOfDay(for: today), in: calendar)
  }

  /// The users on the occasion, in the server's order, each with how many of the user's open gifts are for them on
  /// the occasion's next date. It counts as the web's page does:
  ///
  /// - The user is left out: a gift is never for its giver.
  /// - A gift counts only when it is for this occasion, and its date is the occasion's next date. So an occasion
  ///   with no next date counts none.
  ///
  /// - Parameters:
  ///   - memberIDs: the occasion's users, as the copy has them. Nil when the copy doesn't have them yet.
  ///   - me: the session's user.
  /// - Returns: nil when `memberIDs` is nil.
  public static func counts(
    memberIDs: [String]?, me: String, occasionID: String, nextDate: String?, gifts: [Gift]
  ) -> [Count]? {
    guard let memberIDs else { return nil }
    let own = gifts.filter { $0.occasionID == occasionID && $0.occasionDate == nextDate }
    return memberIDs.filter { $0 != me }.map { userID in
      Count(id: userID, fromYou: own.count { $0.recipientIDs.contains(userID) })
    }
  }
}

extension SessionModel {
  /// A shared occasion's page, from the copy. Nil when the page is the "not found" page: the copy has no such
  /// occasion, because it was deleted or the user can't see it, or the occasion is not a shared one, which has no
  /// page of its own.
  ///
  /// `today` gives the days left, in the device's zone.
  public func sharedOccasionPage(id: String, today: Date = .now) -> SharedOccasionPage? {
    guard let occasion = occasions.first(where: { $0.id == id }), occasion.kind == .shared else { return nil }

    let daysLeft = SharedOccasionPage.daysLeft(until: occasion.nextDate, today: today, timeZone: deviceTimeZone)

    // Only the admin reads the groups of an occasion, so anyone else's copy has no such membership.
    let groupIDs = members(.occasionGroups, of: id) ?? []
    let groupNames = groups.filter { groupIDs.contains($0.id) }.map(\.name)

    let gifts = giving.map { gift in
      SharedOccasionPage.Gift(
        occasionID: gift.occasion?.id, occasionDate: gift.occasionDate, recipientIDs: gift.recipientIDs.value ?? [])
    }
    let counts = SharedOccasionPage.counts(
      memberIDs: members(.usersOfOccasion, of: id), me: session.userID, occasionID: id, nextDate: occasion.nextDate,
      gifts: gifts)
    let people = counts?.compactMap { count in
      user(id: count.id).map { SharedOccasionPage.Person(user: $0, fromYou: count.fromYou) }
    }

    return SharedOccasionPage(
      id: id, name: occasion.name, date: occasion.nextDate, daysLeft: daysLeft,
      isEveryone: occasion.isEveryone ?? false, groupNames: groupNames, people: people)
  }
}
