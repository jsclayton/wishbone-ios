import Foundation

/// Every route of the API that the client calls. The contract test holds each one against the copy of the server's
/// OpenAPI document, so a route that is not here is a route that the app doesn't call. See ADR 0004.
public enum Route: String, Sendable, CaseIterable {
  case health
  case redeemLoginLink
  case versions
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
  case listItems
  case item
  case invitations
  case invitation
  case gifts
  case gift
  case blockedStores
  case revokeCurrentSession
  case confirmProfile
  case uploadImage

  public var method: String {
    switch self {
    case .health, .versions, .users, .user, .groups, .group, .groupUsers, .groupGroups, .occasions, .occasion,
      .occasionGroups, .lists, .list, .listRecipients, .listItems, .item, .invitations, .invitation, .gifts, .gift,
      .blockedStores:
      "GET"
    case .redeemLoginLink, .confirmProfile, .uploadImage: "POST"
    case .updateMe: "PATCH"
    case .revokeCurrentSession: "DELETE"
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
    case .updateMe: "/users/me"
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
    case .list: "/lists/{id}"
    case .listRecipients: "/lists/{id}/recipients"
    case .listItems: "/lists/{id}/items"
    case .item: "/items/{id}"
    case .invitations: "/invitations"
    case .invitation: "/invitations/{id}"
    case .gifts: "/gifts"
    case .gift: "/gifts/{id}"
    case .blockedStores: "/blocked-stores"
    case .revokeCurrentSession: "/users/me/sessions/current"
    case .confirmProfile: "/users/me/confirm-profile"
    case .uploadImage: "/images"
    }
  }

  /// Whether the route is for anyone, signed in or not. A request on such a route never carries the token. So a
  /// redeem never has an `Authorization` header, and the server never revokes a session that the app holds.
  public var isPublic: Bool {
    switch self {
    case .health, .redeemLoginLink: true
    case .versions, .updateMe, .users, .user, .groups, .group, .groupUsers, .groupGroups, .occasions, .occasion,
      .occasionGroups, .lists, .list, .listRecipients, .listItems, .item, .invitations, .invitation, .gifts, .gift,
      .blockedStores, .revokeCurrentSession, .confirmProfile, .uploadImage:
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
    case .groups, .groupUsers, .groupGroups, .occasions, .occasionGroups, .lists, .listRecipients, .listItems,
      .invitations, .gifts, .blockedStores:
      Self.paging
    case .health, .redeemLoginLink, .versions, .updateMe, .user, .group, .occasion, .list, .item, .invitation, .gift,
      .revokeCurrentSession, .confirmProfile, .uploadImage:
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
    case .health, .redeemLoginLink, .users, .user, .groups, .group, .groupUsers, .groupGroups, .occasions, .occasion,
      .occasionGroups, .lists, .list, .listRecipients, .listItems, .item, .invitations, .invitation, .gifts, .gift,
      .blockedStores, .revokeCurrentSession, .confirmProfile, .uploadImage:
      []
    }
  }

  /// The fields of the JSON body that the client sends. `POST /images` sends the bytes of a file, not JSON.
  public var sentFields: [String] {
    switch self {
    case .redeemLoginLink: fields(of: RedeemBody.CodingKeys.self)
    case .updateMe: fields(of: UserChanges.CodingKeys.self, nested: ["birthday": PartialDate.fields])
    case .health, .versions, .users, .user, .groups, .group, .groupUsers, .groupGroups, .occasions, .occasion,
      .occasionGroups, .lists, .list, .listRecipients, .listItems, .item, .invitations, .invitation, .gifts, .gift,
      .blockedStores, .revokeCurrentSession, .confirmProfile, .uploadImage:
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
    case .updateMe, .user, .confirmProfile: User.fields
    case .uploadImage: ImageSummary.fields
    case .users: Page<VersionedRow<User>>.fields
    case .groups: Page<VersionedRow<Group>>.fields
    case .group: Group.fields
    case .occasions: Page<VersionedRow<Occasion>>.fields
    case .occasion: Occasion.fields
    // A membership is read for its IDs only.
    case .groupUsers, .groupGroups, .occasionGroups: Page<Member>.fields
    case .lists: Page<VersionedRow<ListResource>>.fields
    case .list: ListResource.fields
    case .listRecipients: Page<VersionedRow<Recipient>>.fields
    case .listItems: Page<VersionedRow<Item>>.fields
    case .item: Item.fields
    case .invitations: Page<VersionedRow<Invitation>>.fields
    case .invitation: Invitation.fields
    case .gifts: Page<VersionedRow<Gift>>.fields
    case .gift: Gift.fields
    case .blockedStores: Page<VersionedRow<BlockedStore>>.fields
    case .revokeCurrentSession: NoContent.fields
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
  /// Uploads the bytes of an image file. The server reads the file, whatever its type.
  static func uploadImage(_ file: Data) -> Endpoint {
    Endpoint(route: .uploadImage, file: file)
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

extension Endpoint where Response == NoContent {
  /// Signs out: the server revokes the session that the token is of.
  static var revokeCurrentSession: Endpoint {
    Endpoint(route: .revokeCurrentSession)
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
