import Foundation

/// Every route of the API that the client calls. The contract test holds each one against the copy of the server's
/// OpenAPI document, so a route that is not here is a route that the app doesn't call. See ADR 0004.
public enum Route: String, Sendable, CaseIterable {
  case health
  case redeemLoginLink
  case versions
  case me
  case updateMe
  case users
  case user
  case groups
  case group
  case groupUsers
  case groupGroups
  case occasions
  case occasion
  case occasionGroups
  case lists
  case list
  case listRecipients
  case updateList
  case deleteList
  case leaveList
  case listItems
  case item
  case invitations
  case invitation
  case acceptInvitation
  case declineInvitation
  case gifts
  case gift
  case updateGift
  case unclaimGift
  case acknowledgeGift
  case restoreGift
  case claim
  case blockedStores
  case blockStore
  case unblockStore
  case revokeCurrentSession
  case confirmProfile
  case uploadImage
  case search
  case createItem

  public var method: String {
    switch self {
    case .health, .versions, .me, .users, .user, .groups, .group, .groupUsers, .groupGroups, .occasions,
      .occasion, .occasionGroups, .lists, .list, .listRecipients, .listItems, .item, .invitations, .invitation,
      .gifts, .gift, .blockedStores:
      "GET"
    case .redeemLoginLink, .confirmProfile, .uploadImage, .blockStore, .claim, .search, .createItem, .acknowledgeGift,
      .restoreGift, .acceptInvitation:
      "POST"
    case .updateMe, .updateGift, .updateList: "PATCH"
    case .revokeCurrentSession, .unblockStore, .leaveList, .unclaimGift, .deleteList, .declineInvitation: "DELETE"
    }
  }

  /// Whether a request on the route is a write: anything but a `GET`.
  public var isWrite: Bool {
    method != "GET"
  }

  /// The path template under `/api/v2`, as the server's route table writes it.
  public var template: String {
    switch self {
    case .health: "/health"
    case .redeemLoginLink: "/login-links/redeem"
    case .versions: "/versions"
    case .me, .updateMe: "/users/me"
    case .users: "/users"
    case .user: "/users/{id}"
    case .groups: "/groups"
    case .group: "/groups/{id}"
    case .groupUsers: "/groups/{id}/users"
    case .groupGroups: "/groups/{id}/groups"
    case .occasions: "/occasions"
    case .occasion: "/occasions/{id}"
    case .occasionGroups: "/occasions/{id}/groups"
    case .lists: "/lists"
    case .list, .updateList, .deleteList: "/lists/{id}"
    case .listRecipients: "/lists/{id}/recipients"
    case .leaveList: "/lists/{id}/recipients/{user_id}"
    case .listItems, .createItem: "/lists/{id}/items"
    case .item: "/items/{id}"
    case .invitations: "/invitations"
    case .invitation, .declineInvitation: "/invitations/{id}"
    case .acceptInvitation: "/invitations/{id}/accept"
    case .gifts: "/gifts"
    case .gift, .updateGift, .unclaimGift: "/gifts/{id}"
    case .acknowledgeGift: "/gifts/{id}/acknowledge"
    case .restoreGift: "/gifts/{id}/restore"
    case .claim: "/items/{id}/gifts"
    case .blockedStores, .blockStore: "/blocked-stores"
    case .unblockStore: "/blocked-stores/{id}"
    case .revokeCurrentSession: "/users/me/sessions/current"
    case .confirmProfile: "/users/me/confirm-profile"
    case .uploadImage: "/images"
    case .search: "/search"
    }
  }

  /// Whether the route is for anyone, signed in or not. A request on such a route never carries the token. So a
  /// redeem never has an `Authorization` header, and the server never revokes a session that the app holds.
  public var isPublic: Bool {
    switch self {
    case .health, .redeemLoginLink: true
    case .versions, .updateMe, .users, .user, .groups, .group, .groupUsers, .groupGroups, .occasions, .occasion,
      .occasionGroups, .lists, .list, .listRecipients, .listItems, .item, .invitations, .invitation, .gifts, .gift,
      .updateGift, .unclaimGift, .acknowledgeGift, .restoreGift, .claim, .blockedStores, .blockStore, .unblockStore,
      .leaveList, .revokeCurrentSession, .confirmProfile,
      .uploadImage, .me, .search, .createItem, .updateList, .deleteList, .acceptInvitation, .declineInvitation:
      false
    }
  }

  /// The query parameters that the client sends on the route. A request never carries another one: the client
  /// drops a parameter that is not here, so every filter that the client uses must be.
  ///
  /// `GET /versions` has none, and never gets one: the server refuses that route with any query parameter.
  public var queryParameters: [String] {
    switch self {
    // The two filters give the memberships: the users in a group with nesting, and the users of an occasion.
    case .users: Self.paging + ["group_id", "occasion_id"]
    // The item's filter gives the gifts on one item, after a claim that the server says it has already.
    case .gifts: Self.paging + ["item_id"]
    case .groups, .groupUsers, .groupGroups, .occasions, .occasionGroups, .lists, .listRecipients, .listItems,
      .invitations, .blockedStores:
      Self.paging
    case .health, .redeemLoginLink, .versions, .updateMe, .user, .group, .occasion, .list, .item, .invitation, .gift,
      .updateGift, .unclaimGift, .acknowledgeGift, .restoreGift, .claim, .blockStore, .unblockStore, .leaveList,
      .revokeCurrentSession,
      .confirmProfile, .uploadImage, .me,
      .search, .createItem, .updateList, .deleteList, .acceptInvitation, .declineInvitation:
      []
    }
  }

  /// What every collection takes: the size of a page, and the place of the next one.
  private static let paging = ["limit", "cursor"]

  /// The headers that the client sends on the route, beyond the ones that every request has (`User-Agent`,
  /// `Accept`, and `Authorization` and `Content-Type` where they apply).
  public var sentHeaders: [String] {
    switch self {
    case .versions: ["If-None-Match"]
    // A key makes the time zone report safe to send once more after a lost connection.
    case .updateMe: ["Idempotency-Key"]
    // A key makes a block safe to send once more after a lost connection. An unblock is a `DELETE`, which is safe
    // already.
    case .blockStore: ["Idempotency-Key"]
    // A key makes a claim safe to send once more after a lost connection: the server makes the gift once. It
    // never makes a claim an unsent change.
    case .claim: ["Idempotency-Key"]
    // A key makes a restore safe to send once more after a lost connection: the server's first answer comes again,
    // where a second restore would be a 404.
    case .restoreGift: ["Idempotency-Key"]
    // A search's key makes a resend after a lost connection read nothing again. The add's key is the add form's own,
    // so a second Add after a lost answer adds the item once. An upload of a file has a key of its own too, kept by
    // the form or by its unsent change, so a resend uploads the photo once. A download of a store's image sends none.
    case .search, .createItem, .uploadImage: ["Idempotency-Key"]
    // An unsent change keeps its key, so a resend after a lost connection, or in a later sync, is the same write.
    case .updateGift, .unclaimGift, .acknowledgeGift, .updateList, .deleteList, .acceptInvitation,
      .declineInvitation:
      ["Idempotency-Key"]
    case .health, .redeemLoginLink, .users, .user, .groups, .group, .groupUsers, .groupGroups, .occasions, .occasion,
      .occasionGroups, .lists, .list, .listRecipients, .listItems, .item, .invitations, .invitation, .gifts, .gift,
      .blockedStores, .unblockStore, .leaveList, .revokeCurrentSession, .confirmProfile, .me:
      []
    }
  }

  /// The fields of the JSON body that the client sends. `POST /images` sends the bytes of a file, not JSON.
  public var sentFields: [String] {
    switch self {
    case .redeemLoginLink: fields(of: RedeemBody.CodingKeys.self)
    case .updateMe: fields(of: UserChanges.CodingKeys.self, nested: ["birthday": PartialDate.fields])
    case .blockStore: fields(of: BlockStoreBody.CodingKeys.self)
    case .claim: fields(of: ClaimBody.CodingKeys.self)
    case .updateGift: fields(of: GiftChanges.CodingKeys.self)
    case .updateList: fields(of: ListChanges.CodingKeys.self)
    case .acknowledgeGift: fields(of: AcknowledgeBody.CodingKeys.self)
    // A search sends a form, not JSON: its one field is the text, or the photo.
    case .search: ["text", "image"]
    case .createItem:
      fields(of: NewItem.CodingKeys.self, lists: ["store_links": fields(of: NewStoreLink.CodingKeys.self)])
    // An upload sends the bytes of a file, or JSON with the address of one for the server to download.
    case .uploadImage: fields(of: DownloadBody.CodingKeys.self)
    case .health, .versions, .users, .user, .groups, .group, .groupUsers, .groupGroups, .occasions, .occasion,
      .occasionGroups, .lists, .list, .listRecipients, .listItems, .item, .invitations, .invitation, .gifts, .gift,
      .blockedStores, .unblockStore, .leaveList, .revokeCurrentSession, .confirmProfile, .me, .unclaimGift,
      .restoreGift, .deleteList, .acceptInvitation, .declineInvitation:
      []
    }
  }

  /// The fields that the client reads from the route's answer, as key paths. A route whose answer has no body
  /// (a 204) has none.
  public var decodedFields: [String] {
    switch self {
    case .health: Health.fields
    case .redeemLoginLink: RedeemedLoginLink.fields
    case .versions: VersionsBody.fields
    case .me, .updateMe, .user, .confirmProfile: User.fields
    case .uploadImage: ImageSummary.fields
    case .users: Page<VersionedRow<User>>.fields
    case .groups: Page<VersionedRow<Group>>.fields
    case .group: Group.fields
    case .occasions: Page<VersionedRow<Occasion>>.fields
    case .occasion: Occasion.fields
    // A membership is read for its IDs only.
    case .groupUsers, .groupGroups, .occasionGroups: Page<Member>.fields
    case .lists: Page<VersionedRow<ListResource>>.fields
    case .list, .updateList, .acceptInvitation: ListResource.fields
    case .listRecipients: Page<VersionedRow<Recipient>>.fields
    case .listItems: Page<VersionedRow<Item>>.fields
    case .item, .createItem: Item.fields
    case .search: SearchBody.fields
    case .invitations: Page<VersionedRow<Invitation>>.fields
    case .invitation: Invitation.fields
    case .gifts: Page<VersionedRow<Gift>>.fields
    case .gift, .updateGift, .acknowledgeGift, .claim: Gift.fields
    case .blockedStores: Page<VersionedRow<BlockedStore>>.fields
    case .blockStore: BlockedStore.fields
    case .revokeCurrentSession, .unblockStore, .leaveList, .unclaimGift, .restoreGift, .deleteList,
      .declineInvitation:
      NoContent.fields
    }
  }
}

/// One request: a route, with what fills its path template, its query, its body, and its `If-None-Match`.
struct Endpoint<Response: Model>: Sendable {
  let route: Route
  var parameters: [String: String] = [:]
  var query: [URLQueryItem] = []
  var body: (any Encodable & Sendable)?

  /// The bytes of a file, as the body, for a route that takes a file and not JSON.
  var file: Data?

  /// The fields of a `multipart/form-data` body, for a route that takes a form and not JSON.
  var form: [FormField]?

  /// The `ETag` of an earlier answer of the route. The server then answers 304, with no body, when its answer
  /// would be that one again. Only `GET /versions` takes it.
  var ifNoneMatch: String?

  /// The `Idempotency-Key` of a write. A repeat of the write with the same key gets the first answer again, and
  /// the server does no work again. So the client may send a write with a key once more when its connection was
  /// lost. Each write has its own key, made with the endpoint, and its repeat has the same one.
  var idempotencyKey: String?

  /// The path under `/api/v2`, with each parameter in its place.
  var path: String {
    parameters.reduce(route.template) { path, parameter in
      // An ID is an opaque string, so it is encoded as one part of a path.
      let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
      let value = parameter.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? parameter.value
      return path.replacingOccurrences(of: "{\(parameter.key)}", with: value)
    }
  }
}

/// The body of a redeem. A native app asks for a bearer session, which puts the token in the answer.
struct RedeemBody: Encodable, Sendable {
  let token: String
  let session = "bearer"

  enum CodingKeys: String, CodingKey, CaseIterable {
    case token
    case session
  }
}

extension Endpoint where Response == Health {
  static var health: Endpoint {
    Endpoint(route: .health)
  }
}

extension Endpoint where Response == RedeemedLoginLink {
  static func redeem(_ link: LoginLink) -> Endpoint {
    Endpoint(route: .redeemLoginLink, body: RedeemBody(token: link.token))
  }
}

/// The body of `PATCH /users/me`: a merge patch, so a field that is absent doesn't change, and `null` clears a
/// field that can be cleared. The app sets the time zone, and at the profile gate the profile's fields.
public struct UserChanges: Encodable, Sendable, Equatable {
  /// The first name. It can't be cleared.
  public var name: String?

  /// The last name. `.some(nil)` clears it.
  public var lastName: String??

  /// The birthday, with its year or with none. It can't be cleared, so a birthday with no year sends the year as
  /// `null`: a merge patch would otherwise keep the year that the server has.
  public var birthday: PartialDate?

  /// The ID of an uploaded image to use as the avatar. `.some(nil)` removes the avatar.
  public var avatarImageID: String??

  /// The IANA time zone.
  public var timezone: String?

  public init(
    name: String? = nil,
    lastName: String?? = nil,
    birthday: PartialDate? = nil,
    avatarImageID: String?? = nil,
    timezone: String? = nil
  ) {
    self.name = name
    self.lastName = lastName
    self.birthday = birthday
    self.avatarImageID = avatarImageID
    self.timezone = timezone
  }

  /// Whether the patch changes nothing.
  public var isEmpty: Bool {
    self == UserChanges()
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case name
    case lastName = "last_name"
    case birthday
    case avatarImageID = "avatar_image_id"
    case timezone
  }

  private enum BirthdayKeys: String, CodingKey {
    case month
    case day
    case year
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(name, forKey: .name)
    if let lastName { try container.encode(lastName, forKey: .lastName) }
    if let birthday {
      var date = container.nestedContainer(keyedBy: BirthdayKeys.self, forKey: .birthday)
      try date.encode(birthday.month, forKey: .month)
      try date.encode(birthday.day, forKey: .day)
      try date.encode(birthday.year, forKey: .year)
    }
    if let avatarImageID { try container.encode(avatarImageID, forKey: .avatarImageID) }
    try container.encodeIfPresent(timezone, forKey: .timezone)
  }
}

extension Endpoint where Response == User {
  /// The session's own user.
  static var me: Endpoint {
    Endpoint(route: .me)
  }

  static func user(_ id: String) -> Endpoint {
    Endpoint(route: .user, parameters: ["id": id])
  }

  /// Only the session's own user, `me`, is ever patched with a zone. The app never reports a child's.
  static func reportTimeZone(_ identifier: String) -> Endpoint {
    Endpoint(route: .updateMe, body: UserChanges(timezone: identifier), idempotencyKey: UUID().uuidString)
  }

  /// A merge patch of the session's own user.
  static func updateMe(_ changes: UserChanges) -> Endpoint {
    Endpoint(route: .updateMe, body: changes)
  }

  /// Confirms the profile of the session's own user. Only the user can.
  static var confirmProfile: Endpoint {
    Endpoint(route: .confirmProfile)
  }
}

extension Endpoint where Response == ImageSummary {
  /// Uploads the bytes of an image file, with a key, so that a resend uploads it once. The server reads the file,
  /// whatever its type.
  static func uploadImage(_ file: Data, key: String) -> Endpoint {
    Endpoint(route: .uploadImage, file: file, idempotencyKey: key)
  }
}

extension Endpoint where Response == VersionsBody {
  static func versions(ifNoneMatch etag: String?) -> Endpoint {
    Endpoint(route: .versions, ifNoneMatch: etag)
  }
}

extension Endpoint where Response == Group {
  static func group(_ id: String) -> Endpoint {
    Endpoint(route: .group, parameters: ["id": id])
  }
}

extension Endpoint where Response == Occasion {
  static func occasion(_ id: String) -> Endpoint {
    Endpoint(route: .occasion, parameters: ["id": id])
  }
}

extension Endpoint where Response == ListResource {
  static func list(_ id: String) -> Endpoint {
    Endpoint(route: .list, parameters: ["id": id])
  }

  /// A merge patch of the list's name or description, with the unsent change's own key, so that a resend of the
  /// change is the same write. It sends no `If-Match`.
  static func updateList(_ id: String, _ changes: ListChanges, key: String) -> Endpoint {
    Endpoint(route: .updateList, parameters: ["id": id], body: changes, idempotencyKey: key)
  }

  /// Accepts the invitation, with the unsent change's own key. The answer is the list.
  static func acceptInvitation(_ id: String, key: String) -> Endpoint {
    Endpoint(route: .acceptInvitation, parameters: ["id": id], idempotencyKey: key)
  }
}

/// A merge patch of a list: only the fields that change. See `PATCH /lists/{id}` in the server's route table.
public struct ListChanges: Codable, Sendable, Equatable {
  /// The list's name, 1 to 100 characters. It can't be cleared.
  public var name: String?

  /// Markdown about the list, at most 2000 characters. An empty string clears it.
  public var description: String?

  public init(name: String? = nil, description: String? = nil) {
    self.name = name
    self.description = description
  }

  /// Whether the patch changes nothing.
  public var isEmpty: Bool { name == nil && description == nil }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case name
    case description
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(name, forKey: .name)
    try container.encodeIfPresent(description, forKey: .description)
  }
}

extension Endpoint where Response == Item {
  static func item(_ id: String) -> Endpoint {
    Endpoint(route: .item, parameters: ["id": id])
  }
}

extension Endpoint where Response == Invitation {
  static func invitation(_ id: String) -> Endpoint {
    Endpoint(route: .invitation, parameters: ["id": id])
  }
}

extension Endpoint where Response == Gift {
  static func gift(_ id: String) -> Endpoint {
    Endpoint(route: .gift, parameters: ["id": id])
  }
}

/// The body of `POST /gifts/{id}/acknowledge`: the codes of the flags to clear. The app always names them, so an
/// answer clears only its own flag.
struct AcknowledgeBody: Encodable, Sendable {
  let codes: [String]

  enum CodingKeys: String, CodingKey, CaseIterable {
    case codes
  }
}

/// The body of `POST /items/{id}/gifts`: one, for the occasion named, or for the server's own pick when none is. See
/// "Claims are online only" in `docs/spec.md`.
struct ClaimBody: Encodable, Sendable {
  let quantity: Int

  /// One of the occasions that the giver may pick. Nil leaves the pick to the server: the soonest of them.
  let occasionID: String?

  enum CodingKeys: String, CodingKey, CaseIterable {
    case quantity
    case occasionID = "occasion_id"
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(quantity, forKey: .quantity)
    try container.encodeIfPresent(occasionID, forKey: .occasionID)
  }
}

/// The body of `PATCH /gifts/{id}`: a merge patch of only the fields changed, so a field that is absent doesn't
/// change. The giver's unsent changes to an open gift send it, with no `If-Match`. See "No If-Match" in
/// `docs/spec.md`.
public struct GiftChanges: Codable, Sendable, Equatable {
  /// The giver's private mark: bought, or not.
  public var isBought: Bool?

  /// Who the gift is from, at most 60 characters. An empty string clears it.
  public var fromLabel: String?

  /// The giver's private note, at most 2000 characters. An empty string clears it.
  public var note: String?

  /// How many the giver gets, at least 1. A raise is a claim: the server can refuse it with 409
  /// `item_fully_claimed`, and a recipient of the list never raises (403 `quantity_raise_not_allowed`).
  public var quantity: Int?

  /// The occasion: one of `GET /occasions?list_id=` for the gift's list, else 422 `occasion_not_allowed`. A giver who
  /// can see none of the other recipients can't pick one (422 `occasion_locked`). When the giver has another open
  /// gift on the item for that occasion, the two merge, and the answer is the gift that stays.
  public var occasionID: String?

  public init(
    isBought: Bool? = nil, fromLabel: String? = nil, note: String? = nil, quantity: Int? = nil,
    occasionID: String? = nil
  ) {
    self.isBought = isBought
    self.fromLabel = fromLabel
    self.note = note
    self.quantity = quantity
    self.occasionID = occasionID
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case isBought = "is_bought"
    case fromLabel = "from_label"
    case note
    case quantity
    case occasionID = "occasion_id"
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(isBought, forKey: .isBought)
    try container.encodeIfPresent(fromLabel, forKey: .fromLabel)
    try container.encodeIfPresent(note, forKey: .note)
    try container.encodeIfPresent(quantity, forKey: .quantity)
    try container.encodeIfPresent(occasionID, forKey: .occasionID)
  }
}

extension Endpoint where Response == Gift {
  /// A merge patch of the giver's open gift, with the unsent change's own key, so that a resend of the change is the
  /// same write. It sends no `If-Match`.
  static func updateGift(_ id: String, _ changes: GiftChanges, key: String) -> Endpoint {
    Endpoint(route: .updateGift, parameters: ["id": id], body: changes, idempotencyKey: key)
  }

  /// Answers the flags with the codes on the giver's open gift, with the unsent change's own key. Keep it is the
  /// answer `removed`.
  static func acknowledgeGift(_ id: String, codes: [String], key: String) -> Endpoint {
    Endpoint(
      route: .acknowledgeGift, parameters: ["id": id], body: AcknowledgeBody(codes: codes), idempotencyKey: key)
  }

  /// Claims one of the item, for the occasion, or for the soonest occasion that the giver may pick when none is
  /// named, with a key of its own, so that a resend after a lost connection makes one gift.
  static func claim(_ itemID: String, occasionID: String? = nil) -> Endpoint {
    Endpoint(
      route: .claim, parameters: ["id": itemID], body: ClaimBody(quantity: 1, occasionID: occasionID),
      idempotencyKey: UUID().uuidString)
  }
}

extension Endpoint where Response == NoContent {
  /// Signs out: the server revokes the session that the token is of.
  static var revokeCurrentSession: Endpoint {
    Endpoint(route: .revokeCurrentSession)
  }

  /// Takes a store off the blocked list. Only the admin can. It sends no `If-Match` (see "No If-Match" in
  /// `docs/spec.md`).
  static func unblockStore(_ id: String) -> Endpoint {
    Endpoint(route: .unblockStore, parameters: ["id": id])
  }

  /// The giver unclaims their open gift, with the unsent change's own key. It sends no `If-Match` (see "No
  /// If-Match" in `docs/spec.md`).
  static func unclaimGift(_ id: String, key: String) -> Endpoint {
    Endpoint(route: .unclaimGift, parameters: ["id": id], idempotencyKey: key)
  }

  /// A recipient of a given gift, or their parent, says that it didn't arrive, with a key of its own, so that a
  /// resend after a lost connection gets the first answer again.
  static func restoreGift(_ id: String) -> Endpoint {
    Endpoint(route: .restoreGift, parameters: ["id": id], idempotencyKey: UUID().uuidString)
  }

  /// The recipient leaves the extra list, or their parent makes them leave. It sends no `If-Match` (see "No
  /// If-Match" in `docs/spec.md`).
  static func leaveList(_ listID: String, userID: String) -> Endpoint {
    Endpoint(route: .leaveList, parameters: ["id": listID, "user_id": userID])
  }

  /// Deletes the extra list and its items, with the unsent change's own key. It sends no `If-Match`.
  static func deleteList(_ id: String, key: String) -> Endpoint {
    Endpoint(route: .deleteList, parameters: ["id": id], idempotencyKey: key)
  }

  /// Declines the invitation, with the unsent change's own key. It sends no `If-Match`.
  static func declineInvitation(_ id: String, key: String) -> Endpoint {
    Endpoint(route: .declineInvitation, parameters: ["id": id], idempotencyKey: key)
  }
}

/// The body of `POST /blocked-stores`: a host name, or a web address of the store. The server names the store by
/// its host.
struct BlockStoreBody: Encodable, Sendable {
  let store: String

  enum CodingKeys: String, CodingKey, CaseIterable {
    case store
  }
}

extension Endpoint where Response == BlockedStore {
  /// Blocks a store, with a key of its own, so that a resend after a lost connection blocks it once.
  static func blockStore(_ store: String) -> Endpoint {
    Endpoint(route: .blockStore, body: BlockStoreBody(store: store), idempotencyKey: UUID().uuidString)
  }
}

extension Endpoint {
  /// One page of a collection: the largest page that the server gives, from the cursor of the page before it.
  /// `filters` are the route's own query parameters, such as `group_id`.
  static func page<Row>(
    of route: Route,
    id: String? = nil,
    filters: [String: String] = [:],
    cursor: String?
  ) -> Endpoint where Response == Page<Row> {
    var query = filters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    query.append(URLQueryItem(name: "limit", value: String(APIClient.pageSize)))
    if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
    return Endpoint(route: route, parameters: id.map { ["id": $0] } ?? [:], query: query)
  }
}
