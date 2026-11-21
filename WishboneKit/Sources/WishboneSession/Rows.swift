import Foundation
import GRDB
import WishboneAPI

// The rows that screens read. Each is a row of the local copy, which the API feeds and the session model
// publishes. A row is not the API's model of the same thing: it holds what the copy keeps.
//
// Each row keeps its version: the one that its own answer carried when the row was saved. A pull compares it with
// the version that `GET /versions` names. See "No If-Match" in `docs/spec.md`. A summary and a membership have no
// answer of their own, so each keeps the version that `GET /versions` named for it.
//
// A summary inside a body is kept as the ID of what it names: a user's parents and children, the group that a
// group is reached through, the user of an occasion, a user's primary list, a list's recipients, the user who added
// an item, and an invitation's users. Each of those users and groups has a row of its own, and so does the primary
// list when the session's user can see it. An invitation's list can have none, so the invitation keeps its name.
//
// A store link has no answer of its own: the app reads it inside its item. So it keeps the version that
// `GET /versions` named for it.
//
// **A change to what a row keeps is a change to the copy.** So `LocalDatabase.copySchema` rises with it, and a
// fitness test holds this file to that number.

/// A user in the local copy: one whom the session's user sees in full, or only as a summary.
public struct UserRow: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "user"

  public let id: String
  public let name: String
  public let avatar: ImageSummary?

  /// The rest of the user's record: every field that the session's user gets. Nil for a user whom the session's
  /// user gets only as a summary inside another resource. Such a user has a name and an avatar, and no page.
  public let record: Record?

  /// The version of the user as the session's user sees them. For a summary, it is the version of the summary.
  public let version: String

  /// Whether the session's user gets this user only as a summary.
  public var isSummary: Bool {
    record == nil
  }

  /// What a full user has, beyond the summary.
  public struct Record: Codable, Sendable, Equatable {
    public let lastName: String?

    /// Every user has one. Its year can be nil.
    public let birthday: PartialDate

    /// One markdown field that givers can see.
    public let goodToKnow: String?
    public let isAdmin: Bool

    /// The user's parents and children, in the server's order. Each has a row of their own, in full or as a
    /// summary.
    public let parentIDs: [String]
    public let childIDs: [String]

    /// The user's primary list. Nil when the session's user can't see the list: the admin's access shows none.
    public let primaryListID: String?

    /// The user's IANA time zone, such as `Europe/Paris`. Hidden from everyone but the user, their parents, and
    /// the admin.
    public let timezone: Hideable<String>

    /// When the user confirmed their profile. Hidden as the time zone is.
    public let profileConfirmedAt: Hideable<Date>

    /// When the admin deactivated the user. Hidden as the time zone is: anyone else who sees the user sees an
    /// active one.
    public let deactivatedAt: Hideable<Date>
    public let createdAt: Date

    public let canEdit: Bool
    public let canEditParents: Bool
    public let canMakeLoginLink: Bool
    public let canManageSessions: Bool
    public let canDeactivate: Bool
    public let canReactivate: Bool
    public let canConfirmProfile: Bool
    public let canAddOccasion: Bool
  }
}

/// A group in the local copy.
public struct GroupRow: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "group"

  public let id: String
  public let name: String
  public let createdAt: Date

  /// The group that the session's user is directly in, and that this group contains by nesting. Nil when the user
  /// is directly in this group, or is not in it.
  public let throughGroupID: String?

  public let canEdit: Bool
  public let canDelete: Bool
  public let canAddUser: Bool
  public let canAddGroup: Bool

  /// The version of the group as the session's user sees it.
  public let version: String
}

/// An occasion in the local copy.
public struct OccasionRow: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "occasion"

  public let id: String
  public let kind: OccasionKind
  public let name: String
  public let rule: OccasionRule

  /// The user that the occasion is for. Nil for a shared occasion.
  public let userID: String?

  /// For a shared occasion: whether it applies to every user. Nil for the other kinds.
  public let isEveryone: Bool?

  /// The first date of the occasion that is today or later, as `YYYY-MM-DD`. Nil when none is left.
  public let nextDate: String?

  public let canEdit: Bool
  public let canDelete: Bool
  public let canAttachGroup: Bool

  /// The version of the occasion as the session's user sees it.
  public let version: String
}

/// A membership in the local copy: the members of one group, or of one occasion, as one collection of the server
/// gives them to the session's user.
///
/// **The copy has a row only for a membership that the session's user can read.** No row says nothing about the
/// members. It never says that there are none: a row with no members says that. For example, only the admin
/// reads the groups in a group, so anyone else has no such row.
public struct MembershipRow: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "membership"

  public let kind: Kind

  /// The group or the occasion that the members are of.
  public let ownerID: String

  /// The IDs of the members, in the server's order.
  public let memberIDs: [String]

  /// The version that `GET /versions` named for the membership: a hash of the IDs. A membership has no answer
  /// that carries a version.
  public let version: String

  /// Which members of what. Each kind is one collection of the server, and has the server's name for it.
  public enum Kind: String, Codable, Sendable, CaseIterable {
    /// The users directly in a group.
    case groupUsers = "group_users"

    /// The users in a group, directly or through nesting.
    case usersInGroup = "users_in_group"

    /// The users that an occasion applies to.
    case usersOfOccasion = "users_of_occasion"

    /// The groups directly in a group. Only the admin reads it.
    case groupGroups = "group_groups"

    /// The groups that a shared occasion is attached to. Only the admin reads it.
    case occasionGroups = "occasion_groups"
  }
}

/// A list in the local copy: every list that the session's user can see, with the admin's access not counted.
public struct ListRow: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "list"

  public let id: String
  public let name: String

  /// Markdown about the list.
  public let description: String?
  public let isPrimary: Bool

  /// The list's recipients, in the order they became recipients. Each has a row of their own, in full or as a
  /// summary.
  public let recipientIDs: [String]

  /// How many items on the list the session's user can see, as the server counts them.
  public let itemCount: Int
  public let createdAt: Date

  public let canEdit: Bool
  public let canDelete: Bool
  public let canInvite: Bool
  public let canLeave: Bool

  /// The version of the list as the session's user sees it.
  public let version: String
}

/// A recipient of a list in the local copy, as a row of the list's recipients. The list and the user together
/// name it.
public struct RecipientRow: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "recipient"

  public let listID: String

  /// The recipient. They have a row of their own, in full or as a summary.
  public let userID: String

  /// When the user became a recipient.
  public let createdAt: Date

  /// Whether the user could still see the list after they leave it. Hidden from everyone but that user and their
  /// parents.
  public let seesListAfterLeaving: Hideable<Bool>
  public let canDelete: Bool

  /// The version of the row in the list's recipients, as the session's user sees it.
  public let version: String
}

/// An item in the local copy.
///
/// **It holds claim state only as the server sends it to the session's user.** A recipient never gets it, so
/// their own items have it hidden, which is never zero. A giver no longer sees an item that others claimed in
/// full, so it leaves the copy.
public struct ItemRow: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "item"

  public let id: String
  public let listID: String
  public let title: String
  public let notes: String?
  public let priceMinor: Int?
  public let topPriceMinor: Int?
  public let currency: String?
  public let quantity: Int
  public let isUnlimited: Bool

  /// The item's place on its list, from 0.
  public let position: Int

  /// The user who added the item. They have a row of their own, in full or as a summary. Nil once that user is
  /// deleted.
  public let addedByID: String?
  public let createdAt: Date

  /// At most 5, in the order they were added.
  public let images: [ImageSummary]
  public let primaryImage: ImageSummary?

  /// Claim state: how many other givers can still claim. Hidden for a recipient. `shown(nil)` for an unlimited
  /// item.
  public let stillWanted: Hideable<Int>

  /// Claim state: the sum of the session's user's own open gifts on the item. Hidden for a recipient.
  public let myClaimedQuantity: Hideable<Int>

  public let canEdit: Bool
  public let canDelete: Bool
  public let canClaim: Bool
  public let canRefreshPrices: Bool

  /// The version of the item as the session's user sees it.
  public let version: String
}

/// A store link in the local copy. It comes inside its item's body, and is saved with it.
public struct StoreLinkRow: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "storeLink"

  public let id: String
  public let itemID: String

  /// The link's place in its item's body, from 0: the order that the server gives the session's user.
  public let position: Int
  public let url: String
  public let store: String
  public let priceMinor: Int?
  public let currency: String?
  public let capturedAt: Date?
  public let imageURL: String?
  public let createdAt: Date
  public let canEdit: Bool
  public let canDelete: Bool

  /// The version that `GET /versions` named for the store link. No item body carries it.
  public let version: String
}

/// A pending invitation in the local copy.
public struct InvitationRow: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "invitation"

  public let id: String

  /// The list. The invited user can't see it yet, so the copy can have no row for it: the invitation keeps its
  /// name.
  public let listID: String
  public let listName: String

  /// The invited user. They have a row of their own, in full or as a summary.
  public let userID: String

  /// The recipient who invited them. Nil once that user is deleted.
  public let invitedByID: String?
  public let createdAt: Date

  public let canAccept: Bool
  public let canDelete: Bool

  /// The version of the invitation as the session's user sees it.
  public let version: String
}
