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

  /// How many days from today, in the device's zone, to the date: 0 is today. Nil with no date.
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

  /// The users that the occasion applies to whom the session's user can see, in the server's order. Empty says
  /// that it reaches nobody the user sees.
  public let people: [Person]

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

extension SessionModel {
  /// A shared occasion's page, from the copy. Nil when the page is the "not found" page: the copy has no such
  /// occasion, because it was deleted or the user can't see it, or the occasion is not a shared one, which has no
  /// page of its own.
  ///
  /// `today` gives the days left, in the device's zone.
  public func sharedOccasionPage(id: String, today: Date = .now) -> SharedOccasionPage? {
    guard let occasion = occasions.first(where: { $0.id == id }), occasion.kind == .shared else { return nil }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = deviceTimeZone
    let daysLeft = occasion.nextDate.flatMap { HomeOccasions.day(of: $0, in: calendar) }.flatMap { date in
      calendar.dateComponents([.day], from: calendar.startOfDay(for: today), to: date).day
    }

    // Only the admin reads the groups of an occasion, so anyone else's copy has no such membership.
    let groupIDs = members(.occasionGroups, of: id) ?? []
    let groupNames = groups.filter { groupIDs.contains($0.id) }.map(\.name)

    // The user's own open gifts for this occasion on its next date.
    let gifts = giving.filter { gift in
      gift.occasion?.id == id && (occasion.nextDate.map { gift.occasionDate == $0 } ?? true)
    }
    let people = (members(.usersOfOccasion, of: id) ?? []).compactMap { userID in
      user(id: userID).map { user in
        SharedOccasionPage.Person(
          user: user, fromYou: gifts.count { $0.recipientIDs.value?.contains(userID) == true })
      }
    }

    return SharedOccasionPage(
      id: id, name: occasion.name, date: occasion.nextDate, daysLeft: daysLeft,
      isEveryone: occasion.isEveryone ?? false, groupNames: groupNames, people: people)
  }
}
