import Foundation

/// A model that the client decodes from an answer of the API.
///
/// A model ignores the keys that it doesn't name, so a new field on the server breaks nothing. It names the fields
/// that it reads, so the contract test can hold them against the copy of the server's OpenAPI document. See
/// ADR 0004.
public protocol Model: Decodable, Sendable {
  /// The fields that the model reads, as key paths: `name`, `primary_list.id`, `data[].title`.
  static var fields: [String] { get }
}

/// The fields of a model with the given coding keys. `nested` gives the fields of each key that holds a model, and
/// `lists` gives the fields of each key that holds a list of models: `parents[].name`.
func fields<Key: CodingKey & CaseIterable>(
  of keys: Key.Type,
  nested: [String: [String]] = [:],
  lists: [String: [String]] = [:]
) -> [String] {
  keys.allCases.flatMap { key in
    let name = key.stringValue
    if let fields = nested[name] { return fields.map { "\(name).\($0)" } }
    if let fields = lists[name] { return fields.map { "\(name)[].\($0)" } }
    return [name]
  }
}

/// The answer of a route that answers 204, with no body.
public struct NoContent: Model, Equatable {
  public static let fields: [String] = []
}

/// The answer of `GET /health`.
public struct Health: Model, Equatable {
  /// The instance's Wishbone version, such as `2.2.0+7773ada`. A development build reports `dev`.
  public let version: String

  enum CodingKeys: String, CodingKey, CaseIterable {
    case version
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self)
}

/// The answer of `POST /login-links/redeem` for a bearer session.
public struct RedeemedLoginLink: Model {
  /// The new session's token. This answer is the only place where it appears.
  let token: String
  public let userID: String

  /// The first name of the user that the link signs in.
  public let name: String

  enum CodingKeys: String, CodingKey, CaseIterable {
    case token
    case userID = "user_id"
    case name
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self)
}

/// A user, as `GET /users/{id}` gives it, and as a row of `GET /users`: every field that this caller gets. See
/// "User fields" in the server's route table.
public struct User: Model, Equatable {
  public let id: String
  public let name: String
  public let lastName: String?
  public let avatar: ImageSummary?

  /// Every user has one. Its year can be nil.
  public let birthday: PartialDate

  /// One markdown field that givers can see, such as sizes and allergies.
  public let goodToKnow: String?
  public let isAdmin: Bool

  /// The user's parents and children, as summaries. The caller can see each of them only as that summary, unless
  /// the caller also sees them as a user.
  public let parents: [UserSummary]
  public let children: [UserSummary]

  /// The user's primary list. The key is absent for a caller who can't see the list: the admin's access to every
  /// user shows no list. Every user has a primary list, so the field is never `null`.
  public let primaryList: ListSummary?

  /// The user's IANA time zone, such as `Europe/Paris`. Only the user, their parents, and the admin see it.
  public let timezone: Hideable<String>

  /// When the user confirmed their profile. Only the user, their parents, and the admin see it.
  public let profileConfirmedAt: Hideable<Date>

  /// When the admin deactivated the user. Only the user, their parents, and the admin see it. Anyone else who
  /// sees the user sees an active one.
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

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case name
    case lastName = "last_name"
    case avatar
    case birthday
    case goodToKnow = "good_to_know"
    case isAdmin = "is_admin"
    case parents
    case children
    case primaryList = "primary_list"
    case timezone
    case profileConfirmedAt = "profile_confirmed_at"
    case deactivatedAt = "deactivated_at"
    case createdAt = "created_at"
    case canEdit = "can_edit"
    case canEditParents = "can_edit_parents"
    case canMakeLoginLink = "can_make_login_link"
    case canManageSessions = "can_manage_sessions"
    case canDeactivate = "can_deactivate"
    case canReactivate = "can_reactivate"
    case canConfirmProfile = "can_confirm_profile"
    case canAddOccasion = "can_add_occasion"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    lastName = try container.decodeIfPresent(String.self, forKey: .lastName)
    avatar = try container.decodeIfPresent(ImageSummary.self, forKey: .avatar)
    birthday = try container.decode(PartialDate.self, forKey: .birthday)
    goodToKnow = try container.decodeIfPresent(String.self, forKey: .goodToKnow)
    isAdmin = try container.decode(Bool.self, forKey: .isAdmin)
    parents = try container.decode([UserSummary].self, forKey: .parents)
    children = try container.decode([UserSummary].self, forKey: .children)
    primaryList = try container.decodeIfPresent(ListSummary.self, forKey: .primaryList)
    timezone = try container.hideable(String.self, forKey: .timezone)
    profileConfirmedAt = try container.hideableTimestamp(forKey: .profileConfirmedAt)
    deactivatedAt = try container.hideableTimestamp(forKey: .deactivatedAt)
    createdAt = try container.timestamp(forKey: .createdAt)
    canEdit = try container.decode(Bool.self, forKey: .canEdit)
    canEditParents = try container.decode(Bool.self, forKey: .canEditParents)
    canMakeLoginLink = try container.decode(Bool.self, forKey: .canMakeLoginLink)
    canManageSessions = try container.decode(Bool.self, forKey: .canManageSessions)
    canDeactivate = try container.decode(Bool.self, forKey: .canDeactivate)
    canReactivate = try container.decode(Bool.self, forKey: .canReactivate)
    canConfirmProfile = try container.decode(Bool.self, forKey: .canConfirmProfile)
    canAddOccasion = try container.decode(Bool.self, forKey: .canAddOccasion)
  }

  public static let fields = WishboneAPI.fields(
    of: CodingKeys.self,
    nested: ["avatar": ImageSummary.fields, "birthday": PartialDate.fields, "primary_list": ListSummary.fields],
    lists: ["parents": UserSummary.fields, "children": UserSummary.fields])
}

/// A user by their name and avatar, inside another resource. A summary has no last name, and no address.
public struct UserSummary: Model, Equatable {
  public let id: String
  public let name: String
  public let avatar: ImageSummary?

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case name
    case avatar
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self, nested: ["avatar": ImageSummary.fields])
}

/// A group, as `GET /groups/{id}` gives it, and as a row of `GET /groups`.
public struct Group: Model, Equatable {
  public let id: String
  public let name: String
  public let createdAt: Date

  /// The group that the caller is directly in, and that this group contains by nesting. Nil when the caller is
  /// directly in this group, or is not in it.
  public let through: GroupSummary?

  public let canEdit: Bool
  public let canDelete: Bool
  public let canAddUser: Bool
  public let canAddGroup: Bool

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case name
    case createdAt = "created_at"
    case through
    case canEdit = "can_edit"
    case canDelete = "can_delete"
    case canAddUser = "can_add_user"
    case canAddGroup = "can_add_group"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    createdAt = try container.timestamp(forKey: .createdAt)
    through = try container.decodeIfPresent(GroupSummary.self, forKey: .through)
    canEdit = try container.decode(Bool.self, forKey: .canEdit)
    canDelete = try container.decode(Bool.self, forKey: .canDelete)
    canAddUser = try container.decode(Bool.self, forKey: .canAddUser)
    canAddGroup = try container.decode(Bool.self, forKey: .canAddGroup)
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self, nested: ["through": GroupSummary.fields])
}

/// A group by its name, inside another resource.
public struct GroupSummary: Model, Equatable {
  public let id: String
  public let name: String

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case name
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self)
}

/// An occasion, as `GET /occasions/{id}` gives it, and as a row of `GET /occasions`.
public struct Occasion: Model, Equatable {
  public let id: String
  public let kind: OccasionKind

  /// A birthday's name is always "Birthday".
  public let name: String
  public let rule: OccasionRule

  /// The user that the occasion is for. Nil for a shared occasion.
  public let user: UserSummary?

  /// For a shared occasion: whether it applies to every user. Nil for the other kinds.
  public let isEveryone: Bool?

  /// The first date of the occasion that is today or later, as `YYYY-MM-DD`. Nil when none is left.
  public let nextDate: String?

  public let canEdit: Bool
  public let canDelete: Bool
  public let canAttachGroup: Bool

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case kind
    case name
    case rule
    case user
    case isEveryone = "is_everyone"
    case nextDate = "next_date"
    case canEdit = "can_edit"
    case canDelete = "can_delete"
    case canAttachGroup = "can_attach_group"
  }

  public static let fields = WishboneAPI.fields(
    of: CodingKeys.self, nested: ["rule": OccasionRule.fields, "user": UserSummary.fields])
}

/// A row of a collection that the client reads only for the IDs of its members, in the collection's order.
struct Member: Model {
  let id: String

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
  }

  static let fields = WishboneAPI.fields(of: CodingKeys.self)
}

/// A list, as `GET /lists/{id}` gives it, and as a row of `GET /lists`. Its name is not `List`, which is SwiftUI's.
/// See "List fields" in the server's route table.
public struct ListResource: Model, Equatable {
  public let id: String

  /// A primary list's name is its user's name, until someone who can edit the list renames it.
  public let name: String

  /// Markdown about the list.
  public let description: String?

  /// Whether this is the list that every user has from the start, with that user as its only recipient.
  public let isPrimary: Bool

  /// The users the gifts are for, as summaries, in the order they became recipients.
  public let recipients: [UserSummary]

  /// How many items on the list this caller can see. A giver doesn't see a fully claimed item.
  public let itemCount: Int
  public let createdAt: Date

  public let canEdit: Bool
  public let canDelete: Bool
  public let canInvite: Bool
  public let canLeave: Bool

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case name
    case description
    case isPrimary = "is_primary"
    case recipients
    case itemCount = "item_count"
    case createdAt = "created_at"
    case canEdit = "can_edit"
    case canDelete = "can_delete"
    case canInvite = "can_invite"
    case canLeave = "can_leave"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    description = try container.decodeIfPresent(String.self, forKey: .description)
    isPrimary = try container.decode(Bool.self, forKey: .isPrimary)
    recipients = try container.decode([UserSummary].self, forKey: .recipients)
    itemCount = try container.decode(Int.self, forKey: .itemCount)
    createdAt = try container.timestamp(forKey: .createdAt)
    canEdit = try container.decode(Bool.self, forKey: .canEdit)
    canDelete = try container.decode(Bool.self, forKey: .canDelete)
    canInvite = try container.decode(Bool.self, forKey: .canInvite)
    canLeave = try container.decode(Bool.self, forKey: .canLeave)
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self, lists: ["recipients": UserSummary.fields])
}

/// A recipient of a list, as a row of `GET /lists/{id}/recipients`. It has no `GET` of its own.
public struct Recipient: Model, Equatable {
  public let user: UserSummary

  /// When the user became a recipient.
  public let createdAt: Date

  /// Whether the user could still see the list after they leave it. Only that user and their parents get it:
  /// for anyone else the key is absent.
  public let seesListAfterLeaving: Hideable<Bool>

  /// Whether this caller can make the user leave the list: the user, or their parent while the user is active.
  public let canDelete: Bool

  enum CodingKeys: String, CodingKey, CaseIterable {
    case user
    case createdAt = "created_at"
    case seesListAfterLeaving = "sees_list_after_leaving"
    case canDelete = "can_delete"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    user = try container.decode(UserSummary.self, forKey: .user)
    createdAt = try container.timestamp(forKey: .createdAt)
    seesListAfterLeaving = try container.hideable(Bool.self, forKey: .seesListAfterLeaving)
    canDelete = try container.decode(Bool.self, forKey: .canDelete)
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self, nested: ["user": UserSummary.fields])
}

/// A pending invitation to an extra list, as `GET /invitations/{id}` gives it, and as a row of
/// `GET /invitations`. Accepting or declining it removes it.
public struct Invitation: Model, Equatable {
  public let id: String

  /// The list, by its name. The summary doesn't make the list visible: the invited user can't see it yet.
  public let list: ListSummary

  /// The invited user.
  public let user: UserSummary

  /// The recipient who invited them. Nil once that user is deleted.
  public let invitedBy: UserSummary?
  public let createdAt: Date

  public let canAccept: Bool
  public let canDelete: Bool

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case list
    case user
    case invitedBy = "invited_by"
    case createdAt = "created_at"
    case canAccept = "can_accept"
    case canDelete = "can_delete"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    list = try container.decode(ListSummary.self, forKey: .list)
    user = try container.decode(UserSummary.self, forKey: .user)
    invitedBy = try container.decodeIfPresent(UserSummary.self, forKey: .invitedBy)
    createdAt = try container.timestamp(forKey: .createdAt)
    canAccept = try container.decode(Bool.self, forKey: .canAccept)
    canDelete = try container.decode(Bool.self, forKey: .canDelete)
  }

  public static let fields = WishboneAPI.fields(
    of: CodingKeys.self,
    nested: ["list": ListSummary.fields, "user": UserSummary.fields, "invited_by": UserSummary.fields])
}

/// An item, as `GET /items/{id}` gives it, and as a row of `GET /lists/{id}/items`. See "Item fields" in the
/// server's route table.
public struct Item: Model, Equatable {
  public let id: String
  public let listID: String
  public let title: String
  public let notes: String?

  /// The price in the currency's minor unit. A range starts here.
  public let priceMinor: Int?

  /// The top of a price range.
  public let topPriceMinor: Int?

  /// An ISO 4217 code. Nil exactly when there is no price.
  public let currency: String?
  public let quantity: Int
  public let isUnlimited: Bool

  /// The item's place on its list, from 0.
  public let position: Int

  /// The user who added the item, as a summary. Nil once that user is deleted.
  public let addedBy: UserSummary?
  public let createdAt: Date

  /// At most 10, in the order that the server gives this caller: the order added for a caller who can edit the
  /// list, and by price for everyone else.
  public let storeLinks: [StoreLink]

  /// At most 5, in the order they were added.
  public let images: [ImageSummary]

  /// One of `images`. Nil when there are none.
  public let primaryImage: ImageSummary?

  /// **Claim state.** How many other givers can still claim: `shown(nil)` for an unlimited item. Hidden for a
  /// recipient, who never gets the key. Hidden is never zero.
  public let stillWanted: Hideable<Int>

  /// **Claim state.** The sum of this caller's own open gifts on the item. Hidden for a recipient.
  public let myClaimedQuantity: Hideable<Int>

  public let canEdit: Bool
  public let canDelete: Bool
  public let canClaim: Bool
  public let canRefreshPrices: Bool

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case listID = "list_id"
    case title
    case notes
    case priceMinor = "price_minor"
    case topPriceMinor = "top_price_minor"
    case currency
    case quantity
    case isUnlimited = "is_unlimited"
    case position
    case addedBy = "added_by"
    case createdAt = "created_at"
    case storeLinks = "store_links"
    case images
    case primaryImage = "primary_image"
    case stillWanted = "still_wanted"
    case myClaimedQuantity = "my_claimed_quantity"
    case canEdit = "can_edit"
    case canDelete = "can_delete"
    case canClaim = "can_claim"
    case canRefreshPrices = "can_refresh_prices"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    listID = try container.decode(String.self, forKey: .listID)
    title = try container.decode(String.self, forKey: .title)
    notes = try container.decodeIfPresent(String.self, forKey: .notes)
    priceMinor = try container.decodeIfPresent(Int.self, forKey: .priceMinor)
    topPriceMinor = try container.decodeIfPresent(Int.self, forKey: .topPriceMinor)
    currency = try container.decodeIfPresent(String.self, forKey: .currency)
    quantity = try container.decode(Int.self, forKey: .quantity)
    isUnlimited = try container.decode(Bool.self, forKey: .isUnlimited)
    position = try container.decode(Int.self, forKey: .position)
    addedBy = try container.decodeIfPresent(UserSummary.self, forKey: .addedBy)
    createdAt = try container.timestamp(forKey: .createdAt)
    storeLinks = try container.decode([StoreLink].self, forKey: .storeLinks)
    images = try container.decode([ImageSummary].self, forKey: .images)
    primaryImage = try container.decodeIfPresent(ImageSummary.self, forKey: .primaryImage)
    stillWanted = try container.hideable(Int.self, forKey: .stillWanted)
    myClaimedQuantity = try container.hideable(Int.self, forKey: .myClaimedQuantity)
    canEdit = try container.decode(Bool.self, forKey: .canEdit)
    canDelete = try container.decode(Bool.self, forKey: .canDelete)
    canClaim = try container.decode(Bool.self, forKey: .canClaim)
    canRefreshPrices = try container.decode(Bool.self, forKey: .canRefreshPrices)
  }

  public static let fields = WishboneAPI.fields(
    of: CodingKeys.self,
    nested: [
      "added_by": UserSummary.fields, "primary_image": ImageSummary.fields,
    ],
    lists: ["store_links": StoreLink.fields, "images": ImageSummary.fields])
}

/// A store link, inside its item: an address at a store, with the store's price. The app reads store links only
/// from their item's body. A change to a store link changes its item's version.
public struct StoreLink: Model, Equatable {
  public let id: String

  /// The normalized address.
  public let url: String

  /// The host of the address, with no `www.`.
  public let store: String

  /// The store's price in the currency's minor unit.
  public let priceMinor: Int?

  /// An ISO 4217 code. Nil exactly when there is no price.
  public let currency: String?

  /// When the price was captured. Nil when there is no price.
  public let capturedAt: Date?

  /// The store's own address of its picture, outside Wishbone. It loads with no token.
  public let imageURL: String?
  public let createdAt: Date

  public let canEdit: Bool
  public let canDelete: Bool

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case url
    case store
    case priceMinor = "price_minor"
    case currency
    case capturedAt = "captured_at"
    case imageURL = "image_url"
    case createdAt = "created_at"
    case canEdit = "can_edit"
    case canDelete = "can_delete"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    url = try container.decode(String.self, forKey: .url)
    store = try container.decode(String.self, forKey: .store)
    priceMinor = try container.decodeIfPresent(Int.self, forKey: .priceMinor)
    currency = try container.decodeIfPresent(String.self, forKey: .currency)
    capturedAt = try container.decodeIfPresent(String.self, forKey: .capturedAt).map { text in
      try Timestamp.date(text, at: container.codingPath + [CodingKeys.capturedAt])
    }
    imageURL = try container.decodeIfPresent(String.self, forKey: .imageURL)
    createdAt = try container.timestamp(forKey: .createdAt)
    canEdit = try container.decode(Bool.self, forKey: .canEdit)
    canDelete = try container.decode(Bool.self, forKey: .canDelete)
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self)
}

/// A gift, as `GET /gifts/{id}` gives it, and as a row of `GET /gifts`: every field that this caller gets. See
/// "Gift fields" in the server's route table.
///
/// **An open gift is what the device must keep from its recipients.** Only its giver gets it. The fields that only
/// the giver of an open gift sees are hidden for a recipient and their parent, who get only a given gift: the key
/// is absent, and the model keeps it absent.
public struct Gift: Model, Equatable {
  public let id: String
  public let state: GiftState
  public let quantity: Int

  /// The item the gift is of. A giver keeps the gift when the item is deleted, and nobody else sees the item then.
  public let item: GiftItemSummary

  /// The item's list.
  public let list: ListSummary

  /// The item's title, image and price: as they are now for an open gift, and as they were at reveal for a given
  /// one.
  public let title: String
  public let image: ImageSummary?
  public let priceMinor: Int?
  public let topPriceMinor: Int?
  public let currency: String?

  /// The users the gift is for, never its giver: the list's recipients now for an open gift, and the recipients at
  /// reveal for a given one. Hidden when the giver can't see the list, or couldn't at reveal.
  public let recipients: Hideable<[UserSummary]>

  /// The giver. Nil once they are deleted. `giverName` is their name as it was.
  public let giver: UserSummary?
  public let giverName: String
  public let fromLabel: String?

  /// The gift's occasion. Nil when the giver can't see it, or it isn't an occasion of a recipient whom the giver
  /// can see: only the reveal date shows then.
  public let occasion: OccasionSummary?

  /// The occasion's name: as it is now for an open gift, and as it was at reveal for a given one.
  public let occasionName: String?

  /// The date the occasion fell on when the giver picked it, as `YYYY-MM-DD`.
  public let occasionDate: String

  /// When the gift is given.
  public let revealAt: Date

  /// When the gift was given. Nil while it is open.
  public let givenAt: Date?

  /// The giver's own mark that they bought it. Only the giver sees it.
  public let isBought: Hideable<Bool>

  /// The giver's private note. Only the giver sees it.
  public let note: Hideable<String>

  /// What happened to the gift that its giver should answer, oldest first. Only the giver of an open gift sees
  /// them.
  public let flags: Hideable<[GiftFlag]>

  /// Whether the gift needs its giver's attention. Only the giver of an open gift sees it.
  public let needsAttention: Hideable<Bool>

  /// When the giver claimed the item. Only the giver sees it.
  public let createdAt: Hideable<Date>

  public let canEdit: Bool
  public let canDelete: Bool
  public let canRaiseQuantity: Bool
  public let canAcknowledge: Bool
  public let canRestore: Bool
  public let canAddAgain: Bool

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case state
    case quantity
    case item
    case list
    case title
    case image
    case priceMinor = "price_minor"
    case topPriceMinor = "top_price_minor"
    case currency
    case recipients
    case giver
    case giverName = "giver_name"
    case fromLabel = "from_label"
    case occasion
    case occasionName = "occasion_name"
    case occasionDate = "occasion_date"
    case revealAt = "reveal_at"
    case givenAt = "given_at"
    case isBought = "is_bought"
    case note
    case flags
    case needsAttention = "needs_attention"
    case createdAt = "created_at"
    case canEdit = "can_edit"
    case canDelete = "can_delete"
    case canRaiseQuantity = "can_raise_quantity"
    case canAcknowledge = "can_acknowledge"
    case canRestore = "can_restore"
    case canAddAgain = "can_add_again"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    state = try container.decode(GiftState.self, forKey: .state)
    quantity = try container.decode(Int.self, forKey: .quantity)
    item = try container.decode(GiftItemSummary.self, forKey: .item)
    list = try container.decode(ListSummary.self, forKey: .list)
    title = try container.decode(String.self, forKey: .title)
    image = try container.decodeIfPresent(ImageSummary.self, forKey: .image)
    priceMinor = try container.decodeIfPresent(Int.self, forKey: .priceMinor)
    topPriceMinor = try container.decodeIfPresent(Int.self, forKey: .topPriceMinor)
    currency = try container.decodeIfPresent(String.self, forKey: .currency)
    recipients = try container.hideable([UserSummary].self, forKey: .recipients)
    giver = try container.decodeIfPresent(UserSummary.self, forKey: .giver)
    giverName = try container.decode(String.self, forKey: .giverName)
    fromLabel = try container.decodeIfPresent(String.self, forKey: .fromLabel)
    occasion = try container.decodeIfPresent(OccasionSummary.self, forKey: .occasion)
    occasionName = try container.decodeIfPresent(String.self, forKey: .occasionName)
    occasionDate = try container.decode(String.self, forKey: .occasionDate)
    revealAt = try container.timestamp(forKey: .revealAt)
    givenAt = try container.decodeIfPresent(String.self, forKey: .givenAt).map { text in
      try Timestamp.date(text, at: container.codingPath + [CodingKeys.givenAt])
    }
    isBought = try container.hideable(Bool.self, forKey: .isBought)
    note = try container.hideable(String.self, forKey: .note)
    flags = try container.hideable([GiftFlag].self, forKey: .flags)
    needsAttention = try container.hideable(Bool.self, forKey: .needsAttention)
    createdAt = try container.hideableTimestamp(forKey: .createdAt)
    canEdit = try container.decode(Bool.self, forKey: .canEdit)
    canDelete = try container.decode(Bool.self, forKey: .canDelete)
    canRaiseQuantity = try container.decode(Bool.self, forKey: .canRaiseQuantity)
    canAcknowledge = try container.decode(Bool.self, forKey: .canAcknowledge)
    canRestore = try container.decode(Bool.self, forKey: .canRestore)
    canAddAgain = try container.decode(Bool.self, forKey: .canAddAgain)
  }

  public static let fields = WishboneAPI.fields(
    of: CodingKeys.self,
    nested: [
      "item": GiftItemSummary.fields, "list": ListSummary.fields, "image": ImageSummary.fields,
      "giver": UserSummary.fields, "occasion": OccasionSummary.fields,
    ],
    lists: ["recipients": UserSummary.fields, "flags": GiftFlag.fields])
}

/// An item by its title and primary image, inside a gift.
public struct GiftItemSummary: Model, Equatable {
  public let id: String
  public let title: String
  public let primaryImage: ImageSummary?

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case title
    case primaryImage = "primary_image"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    primaryImage = try container.decodeIfPresent(ImageSummary.self, forKey: .primaryImage)
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self, nested: ["primary_image": ImageSummary.fields])
}

/// What happened to an open gift that its giver should answer. Each code has the fields that the server gives it.
/// The enum is open: a code that the app doesn't know is `unknown`, with no fields.
public enum GiftFlag: Model, Equatable {
  /// The item changed since the giver picked the gift: a line for each field, in the order they first changed.
  case changed([GiftChange])

  /// The item was deleted.
  case removed

  /// The item moved to another list. Nil when the giver can't see the new list.
  case moved(to: ListSummary?)

  /// The gift's occasion stopped applying, and the gift moved to another one.
  case occasionMoved

  /// The giver can see none of the list's recipients now.
  case noLongerShared

  /// A recipient said that they didn't get the gift, and it is open again. Nil when the giver can't see who.
  case restored(by: UserSummary?)

  /// The list's recipients changed: the ones the giver last saw, and the ones now. Each is nil when the giver
  /// can't see the list.
  case recipientsChanged(old: [UserSummary]?, new: [UserSummary]?)
  case unknown(String)

  enum CodingKeys: String, CodingKey, CaseIterable {
    case code
    case fields
    case list
    case by
    case oldRecipients = "old_recipients"
    case newRecipients = "new_recipients"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let code = try container.decode(String.self, forKey: .code)
    switch code {
    case "changed": self = .changed(try container.decodeIfPresent([GiftChange].self, forKey: .fields) ?? [])
    case "removed": self = .removed
    case "moved": self = .moved(to: try container.decodeIfPresent(ListSummary.self, forKey: .list))
    case "occasion_moved": self = .occasionMoved
    case "no_longer_shared": self = .noLongerShared
    case "restored": self = .restored(by: try container.decodeIfPresent(UserSummary.self, forKey: .by))
    case "recipients_changed":
      self = .recipientsChanged(
        old: try container.decodeIfPresent([UserSummary].self, forKey: .oldRecipients),
        new: try container.decodeIfPresent([UserSummary].self, forKey: .newRecipients))
    default: self = .unknown(code)
    }
  }

  /// The users that the flag names, as summaries.
  public var users: [UserSummary] {
    switch self {
    case .restored(let by): by.map { [$0] } ?? []
    case .recipientsChanged(let old, let new): (old ?? []) + (new ?? [])
    case .changed, .removed, .moved, .occasionMoved, .noLongerShared, .unknown: []
    }
  }

  public static let fields = WishboneAPI.fields(
    of: CodingKeys.self,
    nested: ["list": ListSummary.fields, "by": UserSummary.fields],
    lists: [
      "fields": GiftChange.fields, "old_recipients": UserSummary.fields, "new_recipients": UserSummary.fields,
    ])
}

/// A blocked store, as a row of `GET /blocked-stores`. Only the admin sees them. `GET /versions` doesn't cover
/// them.
public struct BlockedStore: Model, Equatable {
  public let id: String

  /// A lowercase host with no `www.`. It matches that host and its subdomains.
  public let store: String
  public let createdAt: Date
  public let canDelete: Bool

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case store
    case createdAt = "created_at"
    case canDelete = "can_delete"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    store = try container.decode(String.self, forKey: .store)
    createdAt = try container.timestamp(forKey: .createdAt)
    canDelete = try container.decode(Bool.self, forKey: .canDelete)
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self)
}

/// A resource, with its version as this caller sees it.
///
/// The version comes from the resource's own answer: the `ETag` of its `GET`, or its `version` as a row of a
/// collection. The two are one value, and `GET /versions` names the same one. See "Versions of everything a caller
/// sees" in the server's spec.
public struct Versioned<Resource: Sendable>: Sendable {
  public let resource: Resource
  public let version: String
}

extension Versioned: Equatable where Resource: Equatable {}

/// A row of a collection: the resource, and its `version` beside the resource's own fields.
struct VersionedRow<Resource: Model>: Model {
  let row: Versioned<Resource>

  enum CodingKeys: String, CodingKey, CaseIterable {
    case version
  }

  init(from decoder: any Decoder) throws {
    let version = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .version)
    row = Versioned(resource: try Resource(from: decoder), version: version)
  }

  static var fields: [String] {
    Resource.fields + WishboneAPI.fields(of: CodingKeys.self)
  }
}

/// One entry of `GET /versions`: a resource that this caller can see, and its version.
public struct ResourceVersion: Model, Equatable {
  public let kind: Kind
  public let id: String

  /// The same value as the `ETag` of the resource's own `GET`, and as its `version` in a collection.
  public let version: String

  /// The list of an item, and of a list recipient. Nil for a kind that is on no list.
  public let listID: String?

  /// The item of a store link. Nil for every other kind.
  public let itemID: String?

  /// What an entry is. The enum is open: a kind that the app doesn't know is `unknown`, and the app ignores its
  /// entries. The server has more kinds than these. A kind joins the list when the copy starts to hold it.
  public enum Kind: Sendable, Hashable, Decodable {
    /// A user whom the caller sees in full.
    case user

    /// A user whom the caller gets only as a summary inside another resource. Its version is a hash of the
    /// summary: a summary has no address.
    case userSummary
    case list

    /// A recipient of a list. Its ID is its user's, and its `listID` is the list's: the two together name it. It
    /// has no `GET` of its own, so its version is that of its row in `GET /lists/{id}/recipients`.
    case listRecipient
    case item

    /// A store link. Its `itemID` is its item's. Its version is the `ETag` of the store link's own `GET`, which
    /// the app never calls: no item body carries it.
    case storeLink

    /// A gift: the ones that the caller gives, and the given gifts for them or their children.
    case gift
    case occasion
    case group

    /// A pending invitation.
    case invitation

    /// The memberships. Each entry is one collection of IDs, with the ID of its group or its occasion. Its
    /// version is a hash of the IDs that the collection gives this caller, in the collection's order.
    ///
    /// `GET /groups/{id}/users`: the users directly in a group.
    case groupUsers

    /// `GET /groups/{id}/groups`: the groups directly in a group. Only the admin has these entries.
    case groupGroups

    /// `GET /occasions/{id}/groups`: the groups that a shared occasion is attached to. Only the admin has these
    /// entries.
    case occasionGroups

    /// `GET /users?group_id=`: the users in a group, directly or through nesting.
    case usersInGroup

    /// `GET /users?occasion_id=`: the users that an occasion applies to.
    case usersOfOccasion
    case unknown(String)

    private static let known: [String: Kind] = [
      "user": .user, "user_summary": .userSummary, "list": .list, "list_recipient": .listRecipient, "item": .item,
      "store_link": .storeLink, "gift": .gift, "occasion": .occasion, "group": .group, "invitation": .invitation,
      "group_users": .groupUsers, "group_groups": .groupGroups,
      "occasion_groups": .occasionGroups, "users_in_group": .usersInGroup, "users_of_occasion": .usersOfOccasion,
    ]

    /// The kind for the server's text, such as `item`.
    public init(_ text: String) {
      self = Self.known[text] ?? .unknown(text)
    }

    public init(from decoder: any Decoder) throws {
      self.init(try decoder.singleValueContainer().decode(String.self))
    }
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case kind
    case id
    case version
    case listID = "list_id"
    case itemID = "item_id"
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self)
}

/// The answer of `GET /versions`. It is one answer, with no pages.
struct VersionsBody: Model {
  let data: [ResourceVersion]

  enum CodingKeys: String, CodingKey {
    case data
  }

  static let fields = ResourceVersion.fields.map { "\(CodingKeys.data.stringValue)[].\($0)" }
}

/// What `GET /versions` says: the version of every resource that this caller can see.
public struct Versions: Sendable, Equatable {
  /// One entry for each resource, in no order. A resource with no entry is gone for this caller: deleted, moved
  /// out of view, or hidden. The answer doesn't say which.
  public let entries: [ResourceVersion]

  /// The `ETag` of the whole answer. Sent back as `If-None-Match`, it gets a 304 while no entry has changed.
  public let etag: String?
}

/// How `GET /versions` answered a request that could carry the `ETag` of an earlier answer.
public enum VersionsAnswer: Sendable, Equatable {
  /// A 304: nothing that the earlier answer covers has changed for this caller.
  case unchanged

  /// A 200: the versions as they are now.
  case changed(Versions)
}

/// One page of a collection. The client always follows `next_cursor` to the last page.
struct Page<Row: Model>: Model {
  let data: [Row]
  let nextCursor: String?

  enum CodingKeys: String, CodingKey, CaseIterable {
    case data
    case nextCursor = "next_cursor"
  }

  static var fields: [String] {
    WishboneAPI.fields(of: CodingKeys.self, lists: ["data": Row.fields])
  }
}

/// A whole collection, as the client read it: every row of every page.
public struct FetchedCollection<Row: Sendable>: Sendable {
  public let rows: [Row]

  /// Whether the collection came in one page, which is one answer of the instance. Only then is a thing that is
  /// not in `rows` not in the collection. Between two pages, a thing can change its place in the collection's
  /// order, and be on neither page.
  public let isOnePage: Bool

  public init(rows: [Row], isOnePage: Bool) {
    self.rows = rows
    self.isOnePage = isOnePage
  }
}

/// An error of the API, as `application/problem+json`.
struct Problem: Decodable, Sendable {
  let code: String
  let detail: String

  /// The problems with each field of the input. Only their places are read.
  let errors: [FieldError]?

  struct FieldError: Decodable, Sendable {
    /// Where the problem is, such as `body.name` or `body.birthday.month`.
    let location: String?
  }

  /// The top-level fields of the body that `errors` names, each once, in the server's order: `body.birthday.month`
  /// names `birthday`.
  var fields: [String] {
    var seen: Set<String> = []
    return (errors ?? []).compactMap { error in
      guard let location = error.location else { return nil }
      let parts = location.split(separator: ".")
      guard parts.first == "body", parts.count > 1 else { return nil }
      // A place in a list, such as `parent_ids[1]`, names the list.
      let field = String(parts[1].prefix { $0 != "[" })
      return seen.insert(field).inserted ? field : nil
    }
  }
}
