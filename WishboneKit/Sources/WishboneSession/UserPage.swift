import Foundation
import WishboneAPI

// A user's page, from the copy: the header, the line for a special case, good to know, the items of the user's
// primary list, and their other lists. See `docs/screens/user.md`, and in `docs/spec.md`: "How each thing is
// reached", "Claim state on a child's list", "A deactivated child", and "The admin's For {name} part".
//
// **Claim state shows only as the server sends it.** An item's claim state is the server's `still_wanted` and
// `my_claimed_quantity`, which only a giver and a parent who is not a recipient get. The user's own page never
// shows it. Nothing here says who claimed.

/// What a user's page shows. The session model builds it from the copy: see `SessionModel.userPage(id:today:)`.
public struct UserPage: Equatable, Sendable {
  /// The user, in full.
  public let user: UserRow

  /// The user's record: what a full user has beyond the summary.
  public let record: UserRow.Record

  /// Whether this is the session's user's own page. It has no claim state.
  public let isOwn: Bool

  /// The birthday, and the age that the user is turning when it has a year.
  public let birthday: Birthday

  /// The line for a special case, under the header. Nil when none applies.
  public let notice: Notice?

  /// The user's primary list. Nil when the session's user can't see it, as through the admin's access, or before
  /// the copy has it.
  public let primaryList: ListRow?

  /// Whether the line "You see what's been claimed here. Fully claimed items don't show." shows above the items:
  /// the session's user is a parent of a recipient of the primary list, and not a recipient.
  public let seesClaimsAsParent: Bool

  /// The items of the primary list, in the list's order. A giver's copy has no item that others claimed in full.
  public let items: [Item]

  /// The extra lists that the user is a recipient of, and that the session's user can see, by name. Empty hides
  /// the part.
  public let otherLists: [ListRow]

  /// A birthday as the header shows it.
  public struct Birthday: Equatable, Sendable {
    public let month: Int
    public let day: Int

    /// The age that the user turns on their next birthday, today or later. Nil when the birthday has no year.
    public let turning: Int?

    public init(month: Int, day: Int, turning: Int?) {
      self.month = month
      self.day = day
      self.turning = turning
    }
  }

  /// The line for a special case.
  public enum Notice: Equatable, Sendable {
    /// For a parent: "Only the admin can reactivate {name}. Until then, you can't change anything for {name}."
    case deactivatedChild

    /// For the admin, who sees the user only through the admin's access: "You see {name} because you're the admin.
    /// Their lists show only to people who share a group with them."
    case adminAccess
  }

  /// An item of the primary list, with its claim state as the session's user may see it.
  public struct Item: Equatable, Sendable, Identifiable {
    public let row: ItemRow

    /// Nil when the page shows no claim state: on the user's own page, and for any recipient.
    public let claim: Claim?

    public var id: String { row.id }
  }

  /// An item's claim state, as the server sends it.
  public struct Claim: Equatable, Sendable {
    /// How many other givers can still claim. Nil for an item that is always wanted.
    public let stillWanted: Int?

    /// How many the item asks for.
    public let quantity: Int

    /// The sum of the session's user's own open gifts on the item. Zero says nothing.
    public let youClaimed: Int

    public init(stillWanted: Int?, quantity: Int, youClaimed: Int) {
      self.stillWanted = stillWanted
      self.quantity = quantity
      self.youClaimed = youClaimed
    }
  }
}

extension UserPage.Birthday {
  /// The birthday, with the age that the user turns on the first birthday that is `today` or later, in the
  /// calendar's zone.
  public init(_ date: PartialDate, today: Date, calendar: Calendar) {
    let turning = date.year.map { year in
      let now = calendar.dateComponents([.year, .month, .day], from: today)
      let thisYear = now.year ?? year
      let isLater = (date.month, date.day) >= (now.month ?? 1, now.day ?? 1)
      return (isLater ? thisYear : thisYear + 1) - year
    }
    self.init(month: date.month, day: date.day, turning: turning)
  }
}

extension SessionModel {
  /// The user's page, from the copy. Nil when the page is the "not found" page: the user is not in the copy, or
  /// the copy holds them only as a summary, which has no page on the server.
  ///
  /// `today` gives the age that the user is turning, in the device's zone.
  public func userPage(id: String, today: Date = .now) -> UserPage? {
    guard let user = user(id: id), let record = user.record else { return nil }
    let me = session.userID
    let isOwn = id == me
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .gmt

    let notice: UserPage.Notice? =
      if isOwn {
        nil
      } else if user.isDeactivated && !record.canReactivate {
        // Only the admin can reactivate, and the admin has another line, in the For part.
        .deactivatedChild
      } else if record.primaryListID == nil && self.user?.record?.isAdmin == true {
        // Every user has a primary list. Only the admin's access shows a user with no primary list.
        .adminAccess
      } else {
        nil
      }

    let primaryList = record.primaryListID.flatMap { list(id: $0) }
    let isRecipient = primaryList?.recipientIDs.contains(me) ?? false
    let children = Set(self.user?.record?.childIDs ?? [])
    let seesClaimsAsParent =
      !isOwn && !isRecipient && primaryList?.recipientIDs.contains { children.contains($0) } == true
    let items = primaryList.map { items(onList: $0.id) } ?? []

    return UserPage(
      user: user,
      record: record,
      isOwn: isOwn,
      birthday: UserPage.Birthday(record.birthday, today: today, calendar: calendar),
      notice: notice,
      primaryList: primaryList,
      seesClaimsAsParent: seesClaimsAsParent,
      items: items.map { UserPage.Item(row: $0, claim: isOwn || isRecipient ? nil : UserPage.Claim($0)) },
      otherLists: lists.filter { !$0.isPrimary && $0.recipientIDs.contains(id) }
    )
  }
}

extension UserPage.Claim {
  /// The item's claim state as the server sent it. Nil when the server hid it.
  init?(_ item: ItemRow) {
    guard case .shown(let stillWanted) = item.stillWanted else { return nil }
    self.init(stillWanted: stillWanted, quantity: item.quantity, youClaimed: item.myClaimedQuantity.value ?? 0)
  }
}
