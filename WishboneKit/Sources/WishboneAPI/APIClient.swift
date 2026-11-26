import Foundation

/// The client of one instance's API. It is built from the instance address, and from the session's token once the
/// device is signed in. See "The API client" in `docs/architecture.md`, and ADR 0004.
///
/// Its state is all `let`, and it is not on the main actor.
public struct APIClient: Sendable {
  public let instance: InstanceAddress

  private let token: String?
  private let userAgent: UserAgent
  private let clock: any Clock<Duration>
  private let timeout: Duration
  private let diagnostics: any DiagnosticsReporter

  /// A client with no session, for the version check and the redeem of a login link.
  public init(
    instance: InstanceAddress,
    userAgent: UserAgent,
    clock: any Clock<Duration> = ContinuousClock(),
    timeout: Duration = .seconds(30),
    diagnostics: any DiagnosticsReporter = .none
  ) {
    self.instance = instance
    token = nil
    self.userAgent = userAgent
    self.clock = clock
    self.timeout = timeout
    self.diagnostics = diagnostics
  }

  /// The client of a session.
  public init(
    session: Session,
    userAgent: UserAgent,
    clock: any Clock<Duration> = ContinuousClock(),
    timeout: Duration = .seconds(30),
    diagnostics: any DiagnosticsReporter = .none
  ) {
    instance = session.instance
    token = session.token
    self.userAgent = userAgent
    self.clock = clock
    self.timeout = timeout
    self.diagnostics = diagnostics
  }

  // MARK: - The routes

  /// `GET /health`: the instance's version. It needs no token. The version tags every event of diagnostics.
  public func health() async throws(APIError) -> Health {
    let health = try await load(.health)
    diagnostics.wishboneVersion(ServerVersion(health.version))
    return health
  }

  /// `POST /login-links/redeem`: uses the link, and starts a bearer session. The link works once.
  public func redeem(_ link: LoginLink) async throws(APIError) -> (session: Session, name: String) {
    let redeemed = try await load(.redeem(link))
    return (Session(instance: instance, token: redeemed.token, userID: redeemed.userID), redeemed.name)
  }

  /// `GET /versions`: the version of everything that the session's user can see, in one answer.
  ///
  /// With the `ETag` of an earlier answer, the server answers 304 when nothing has changed since, and the result
  /// is `unchanged`. The request never has a query. An API's own 404 here means an instance below the minimum
  /// server version, which has no such route.
  public func versions(ifNoneMatch etag: String?) async throws(APIError) -> VersionsAnswer {
    guard let answer = try await answer(to: .versions(ifNoneMatch: etag)) else { return .unchanged }
    return .changed(Versions(entries: answer.body.data, etag: answer.etag))
  }

  /// `GET /users/me`: the session's own user, with its version.
  public func me() async throws(APIError) -> Versioned<User> {
    try await versioned(.me)
  }

  /// `PATCH /users/me` with the time zone: sets the IANA zone on the session's own user, and gives back the user,
  /// with the version that the answer carried.
  public func reportTimeZone(_ identifier: String) async throws(APIError) -> Versioned<User> {
    try await versioned(.reportTimeZone(identifier))
  }

  /// `PATCH /users/me`: a merge patch of the session's own user. Gives back the user, with the version that the
  /// answer carried.
  public func updateMe(_ changes: UserChanges) async throws(APIError) -> Versioned<User> {
    try await versioned(.updateMe(changes))
  }

  /// `POST /users/me/confirm-profile`: the session's own user confirms their profile. Gives back the user, with the
  /// version that the answer carried. A profile that is already confirmed keeps its first time.
  public func confirmProfile() async throws(APIError) -> Versioned<User> {
    try await versioned(.confirmProfile)
  }

  /// `POST /images`: uploads the bytes of an image file. The image is attached to nothing until a write names its
  /// ID, and the server deletes it a day later if nothing does.
  public func uploadImage(_ file: Data) async throws(APIError) -> ImageSummary {
    try await load(.uploadImage(file))
  }

  /// `POST /images` with an address: the server downloads the image, such as a store's image from a search. It
  /// refuses one that it can't fetch with 422 `image_fetch_failed`.
  public func downloadImage(_ address: String) async throws(APIError) -> ImageSummary {
    try await load(.downloadImage(address))
  }

  /// `POST /search`: reads a link, or takes typed words as they are, and gives what the add form shows. It saves
  /// nothing. A link is read on the server, never by the app.
  public func search(_ text: String) async throws(APIError) -> SearchResult {
    try Self.only(await load(.search(text)))
  }

  /// `POST /search` with a photo, as the bytes of a JPEG: the server guesses a title, and a price when the photo
  /// shows one. With no model on the instance, nothing is found. It refuses a file over its limit with 413
  /// `image_too_large` (or `request_too_large`), and a file that isn't an image with 422 `image_invalid`.
  public func search(photo jpeg: Data) async throws(APIError) -> SearchResult {
    try Self.only(await load(.search(photo: jpeg)))
  }

  /// The one result of a search.
  private static func only(_ body: SearchBody) throws(APIError) -> SearchResult {
    guard let result = body.results.first else {
      throw .undecodable(.init(route: .search, keyPath: "results"))
    }
    return result
  }

  /// `POST /lists/{id}/items`: adds the item at the end of the list. `key` is the add's `Idempotency-Key`. Gives
  /// back the item, with the version that the answer carried.
  public func createItem(_ item: NewItem, onList listID: String, key: String) async throws(APIError)
    -> Versioned<Item>
  {
    try await versioned(.createItem(item, onList: listID, key: key))
  }

  /// The request for an image of the instance, such as an avatar, with the session's token. The image's address is
  /// a path under `/api/v2`. Nil for any other address, which never gets the token.
  public func imageRequest(_ image: ImageSummary) -> URLRequest? {
    let prefix = InstanceAddress.apiPrefix + "/"
    guard image.url.hasPrefix(prefix), let url = instance.url(path: String(image.url.dropFirst(prefix.count - 1)))
    else { return nil }
    var request = URLRequest(url: url)
    request.setValue(userAgent.text, forHTTPHeaderField: "User-Agent")
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    return request
  }

  /// The bytes of an image of the instance, with the session's token, or nil when there are none: no connection,
  /// any answer but a 200, or an address that is not the instance's. See "Images" in `docs/spec.md`.
  ///
  /// It follows no redirect, so the token never goes to another address. With `onlyOnALowCostNetwork`, the system
  /// refuses the request on an expensive or a constrained network.
  ///
  /// Diagnostics: never. A failed image load is not captured, and not a breadcrumb.
  public func imageBytes(_ image: ImageSummary, onlyOnALowCostNetwork: Bool = false) async -> Data? {
    guard var request = imageRequest(image) else { return nil }
    if onlyOnALowCostNetwork {
      request.allowsExpensiveNetworkAccess = false
      request.allowsConstrainedNetworkAccess = false
    }
    do {
      let (body, response) = try await withTimeout(timeout, clock: clock) { [request] in
        try await Self.urlSession.data(for: request, delegate: NoRedirects())
      }
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        Log.notice(.api, "An image didn't load: the instance gave no image.")
        return nil
      }
      return body
    } catch {
      Log.notice(.api, "An image didn't load.", detail: "\(error)")
      return nil
    }
  }

  /// The request for a store's image, from a store link's `image_url`. It never has the token, whatever its address.
  /// It loads through the system's default cache. Nil for a text that is not an `http` or `https` address.
  public static func storeImageRequest(_ address: String) -> URLRequest? {
    guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
    return URLRequest(url: url)
  }

  // MARK: - Users, groups and occasions

  /// `GET /users`: every user that the session's user can see, each with its version.
  public func users() async throws(APIError) -> FetchedCollection<Versioned<User>> {
    try await rows { cursor in .page(of: .users, cursor: cursor) }
  }

  /// `GET /users/{id}`: one user. A 404 for a user whom the session's user sees only as a summary.
  public func user(_ id: String) async throws(APIError) -> Versioned<User> {
    try await versioned(.user(id))
  }

  /// `GET /groups`: the groups that the session's user is in, directly or through nesting. The admin gets every
  /// group.
  public func groups() async throws(APIError) -> FetchedCollection<Versioned<Group>> {
    try await rows { cursor in .page(of: .groups, cursor: cursor) }
  }

  /// `GET /groups/{id}`: one group.
  public func group(_ id: String) async throws(APIError) -> Versioned<Group> {
    try await versioned(.group(id))
  }

  /// `GET /occasions`: every occasion that the session's user can see.
  public func occasions() async throws(APIError) -> FetchedCollection<Versioned<Occasion>> {
    try await rows { cursor in .page(of: .occasions, cursor: cursor) }
  }

  /// `GET /occasions/{id}`: one occasion.
  public func occasion(_ id: String) async throws(APIError) -> Versioned<Occasion> {
    try await versioned(.occasion(id))
  }

  // MARK: - Memberships

  // Each membership is the IDs that its collection gives the session's user, in the collection's order. These are
  // the IDs that `GET /versions` hashes for the membership's entry. Its version is the `ETag` of the collection's
  // answers, which is the same value as that entry's version (see `members`).

  /// `GET /groups/{id}/users`: the users directly in the group.
  public func userIDs(directlyInGroup id: String) async throws(APIError) -> Versioned<[String]> {
    try await members { cursor in .page(of: .groupUsers, id: id, cursor: cursor) }
  }

  /// `GET /users?group_id=`: the users in the group, directly or through nesting, whom the session's user can see.
  /// A group that is gone, or hidden, gives none.
  public func userIDs(inGroup id: String) async throws(APIError) -> Versioned<[String]> {
    try await members { cursor in .page(of: .users, filters: ["group_id": id], cursor: cursor) }
  }

  /// `GET /users?occasion_id=`: the users that the occasion applies to, whom the session's user can see. An
  /// occasion that is gone, or hidden, gives none.
  public func userIDs(ofOccasion id: String) async throws(APIError) -> Versioned<[String]> {
    try await members { cursor in .page(of: .users, filters: ["occasion_id": id], cursor: cursor) }
  }

  /// `GET /groups/{id}/groups`: the groups directly in the group. Only the admin can read it.
  public func groupIDs(directlyInGroup id: String) async throws(APIError) -> Versioned<[String]> {
    try await members { cursor in .page(of: .groupGroups, id: id, cursor: cursor) }
  }

  /// `GET /occasions/{id}/groups`: the groups that the shared occasion is attached to. Only the admin can read it.
  public func groupIDs(ofOccasion id: String) async throws(APIError) -> Versioned<[String]> {
    try await members { cursor in .page(of: .occasionGroups, id: id, cursor: cursor) }
  }

  // MARK: - Lists, items and invitations

  /// `GET /lists`: every list that the session's user can see, with the admin's access not counted, each with its
  /// version.
  public func lists() async throws(APIError) -> FetchedCollection<Versioned<ListResource>> {
    try await rows { cursor in .page(of: .lists, cursor: cursor) }
  }

  /// `GET /lists/{id}`: one list.
  public func list(_ id: String) async throws(APIError) -> Versioned<ListResource> {
    try await versioned(.list(id))
  }

  /// `GET /lists/{id}/recipients`: the list's recipients, in the order they became recipients, each with its
  /// version. A recipient has no address of its own.
  public func recipients(ofList id: String) async throws(APIError) -> FetchedCollection<Versioned<Recipient>> {
    try await rows { cursor in .page(of: .listRecipients, id: id, cursor: cursor) }
  }

  /// `GET /lists/{id}/items`: every item on the list, in the list's order, each with its version.
  public func items(ofList id: String) async throws(APIError) -> FetchedCollection<Versioned<Item>> {
    try await rows { cursor in .page(of: .listItems, id: id, cursor: cursor) }
  }

  /// `GET /items/{id}`: one item, with its store links.
  public func item(_ id: String) async throws(APIError) -> Versioned<Item> {
    try await versioned(.item(id))
  }

  /// `GET /invitations`: every pending invitation that the session's user can see, each with its version.
  public func invitations() async throws(APIError) -> FetchedCollection<Versioned<Invitation>> {
    try await rows { cursor in .page(of: .invitations, cursor: cursor) }
  }

  /// `GET /invitations/{id}`: one invitation.
  public func invitation(_ id: String) async throws(APIError) -> Versioned<Invitation> {
    try await versioned(.invitation(id))
  }

  // MARK: - Gifts and blocked stores

  /// `GET /gifts`: every gift that the session's user can see, each with its version: the ones they give, and the
  /// given gifts for them or their children.
  public func gifts() async throws(APIError) -> FetchedCollection<Versioned<Gift>> {
    try await rows { cursor in .page(of: .gifts, cursor: cursor) }
  }

  /// `GET /gifts/{id}`: one gift. A 404 for a gift that the session's user can't see, which an open gift is for
  /// everyone but its giver.
  public func gift(_ id: String) async throws(APIError) -> Versioned<Gift> {
    try await versioned(.gift(id))
  }

  /// `GET /gifts?item_id=`: the gifts on one item that the session's user can see, each with its version. For a
  /// giver, these are their own.
  public func gifts(ofItem itemID: String) async throws(APIError) -> FetchedCollection<Versioned<Gift>> {
    try await rows { cursor in .page(of: .gifts, filters: ["item_id": itemID], cursor: cursor) }
  }

  /// `POST /items/{id}/gifts`: claims one of the item, for the occasion, or for the soonest occasion that the giver
  /// may pick when `occasionID` is nil. Gives back the gift, with the version that the answer carried. A giver who
  /// has a gift on the item for that occasion already gets a 409 `already_claimed`, a giver who comes after the last
  /// one a 409 `item_fully_claimed`, and an occasion that the giver may not pick is a 422 `occasion_not_allowed`.
  public func claim(_ itemID: String, occasionID: String? = nil) async throws(APIError) -> Versioned<Gift> {
    try await versioned(.claim(itemID, occasionID: occasionID))
  }

  /// `PATCH /gifts/{id}`: a merge patch of the giver's open gift, with no `If-Match`. `key` is the unsent change's
  /// own `Idempotency-Key`. Gives back the gift, with the version that the answer carried. When a change of the
  /// occasion merges two gifts, the answer is the gift that stays.
  public func updateGift(_ id: String, _ changes: GiftChanges, key: String) async throws(APIError)
    -> Versioned<Gift>
  {
    try await versioned(.updateGift(id, changes, key: key))
  }

  /// `DELETE /gifts/{id}`: the giver unclaims their open gift, with no `If-Match`, and the quantity goes back to all
  /// givers. `key` is the unsent change's own `Idempotency-Key`. A given gift is a 403 `gift_given`.
  public func unclaimGift(_ id: String, key: String) async throws(APIError) {
    _ = try await load(.unclaimGift(id, key: key))
  }

  /// `POST /gifts/{id}/acknowledge`: the giver answers the flags with the codes, such as `removed` for Keep it.
  /// `key` is the unsent change's own `Idempotency-Key`. Gives back the gift, with the version that the answer
  /// carried.
  public func acknowledgeGift(_ id: String, codes: [String], key: String) async throws(APIError) -> Versioned<Gift> {
    try await versioned(.acknowledgeGift(id, codes: codes, key: key))
  }

  /// `POST /gifts/{id}/restore`: I didn't get this. A recipient of a given gift, or their parent, says that it
  /// didn't arrive. The gift opens again for its giver, or is deleted when the giver is deleted or deactivated, and
  /// is a 404 for the caller from then on. An open gift, or one the caller gave, is a 403.
  public func restoreGift(_ id: String) async throws(APIError) {
    _ = try await load(.restoreGift(id))
  }

  /// `GET /blocked-stores`: every blocked store, each with its version. Only the admin can read it.
  public func blockedStores() async throws(APIError) -> FetchedCollection<Versioned<BlockedStore>> {
    try await rows { cursor in .page(of: .blockedStores, cursor: cursor) }
  }

  /// `POST /blocked-stores`: blocks the store that a host name or a web address names. Gives back the blocked
  /// store, with the version that the answer carried. A store that is blocked already is a 409 `already_blocked`.
  public func blockStore(_ store: String) async throws(APIError) -> Versioned<BlockedStore> {
    try await versioned(.blockStore(store))
  }

  /// `DELETE /blocked-stores/{id}`: takes the store off the blocked list.
  public func unblockStore(_ id: String) async throws(APIError) {
    _ = try await load(.unblockStore(id))
  }

  /// `DELETE /lists/{id}/recipients/{user_id}`: the user leaves the list, or their parent makes them leave.
  public func leave(list listID: String, userID: String) async throws(APIError) {
    _ = try await load(.leaveList(listID, userID: userID))
  }

  /// `DELETE /users/me/sessions/current`: signs out. The server revokes the session, and the token works no more.
  public func revokeCurrentSession() async throws(APIError) {
    _ = try await load(.revokeCurrentSession)
  }

  // MARK: - Collections

  /// How many rows the client asks for in a page of a collection. It is the most that the server gives.
  public static let pageSize = 200

  /// Every page of a collection. It follows `next_cursor` to the last page.
  private func collection<Row>(
    _ page: (_ cursor: String?) -> Endpoint<Page<Row>>
  ) async throws(APIError) -> FetchedCollection<Row> {
    var rows: [Row] = []
    var pages = 0
    var cursor: String?
    repeat {
      let answer = try await load(page(cursor))
      rows += answer.data
      pages += 1
      cursor = answer.nextCursor
    } while cursor != nil
    return FetchedCollection(rows: rows, isOnePage: pages == 1)
  }

  /// A collection of resources, each with its version.
  private func rows<Resource>(
    _ page: (_ cursor: String?) -> Endpoint<Page<VersionedRow<Resource>>>
  ) async throws(APIError) -> FetchedCollection<Versioned<Resource>> {
    let collection = try await collection(page)
    return FetchedCollection(rows: collection.rows.map(\.row), isOnePage: collection.isOnePage)
  }

  /// How many times the client reads a membership whose pages keep differing, before it takes the last read.
  static let membershipReads = 3

  /// The IDs of a membership, in the collection's order, with the membership's version: the `ETag` of its answers.
  /// An ID that came on two pages is there once, at its first place.
  ///
  /// The server gives a membership's whole collection one `ETag`, the same on every page. Two pages with different
  /// `ETag`s mean that the membership changed between them, so the client reads it again from its first page. A
  /// membership that still differs after `membershipReads` reads has the empty version, which agrees with nothing
  /// that `GET /versions` names, so the next pull reads it again. See "Versions" in the server's route table.
  private func members(
    _ page: (_ cursor: String?) -> Endpoint<Page<Member>>
  ) async throws(APIError) -> Versioned<[String]> {
    var ids: [String] = []
    var versions: Set<String> = []
    for _ in 0..<Self.membershipReads {
      ids = []
      versions = []
      var cursor: String?
      repeat {
        // A 304 answers only a request with `If-None-Match`, so this request has an answer.
        guard let answer = try await answer(to: page(cursor)) else { throw .unreachable(.notTheAPI) }
        ids += answer.body.data.map(\.id)
        versions.insert(Self.version(ofETag: answer.etag))
        cursor = answer.body.nextCursor
      } while cursor != nil
      if versions.count == 1 { break }
    }
    var seen: Set<String> = []
    let version = versions.count == 1 ? versions.first ?? "" : ""
    return Versioned(resource: ids.filter { seen.insert($0).inserted }, version: version)
  }

  // MARK: - The one load

  /// The answer of a route with no `If-None-Match`.
  private func load<Response>(_ endpoint: Endpoint<Response>) async throws(APIError) -> Response {
    // A 304 answers only a request with `If-None-Match`, so this request has an answer.
    guard let answer = try await answer(to: endpoint) else { throw .unreachable(.notTheAPI) }
    return answer.body
  }

  /// A resource from its own address, with the `ETag` of the answer as its version.
  private func versioned<Resource>(_ endpoint: Endpoint<Resource>) async throws(APIError) -> Versioned<Resource> {
    guard let answer = try await answer(to: endpoint) else { throw .unreachable(.notTheAPI) }
    return Versioned(resource: answer.body, version: Self.version(ofETag: answer.etag))
  }

  /// The version that an `ETag` gives. `GET /versions` names a version as the strong tag, so a tag that something
  /// on the way made weak (`W/`) is the same version. An answer with no `ETag` has the empty version, which agrees
  /// with nothing that `GET /versions` names, so the resource is fetched again at the next pull.
  private static func version(ofETag etag: String?) -> String {
    guard let etag else { return "" }
    return etag.hasPrefix("W/") ? String(etag.dropFirst(2)) : etag
  }

  /// What a route answered: the decoded body, and the answer's `ETag`.
  private struct Answer<Response> {
    let body: Response
    let etag: String?
  }

  /// Every request goes through here: the user agent, the token, the time limit, the log, the strict test for the
  /// API's own answers, the rule for an unreachable instance, and diagnostics.
  ///
  /// Nil is a 304 for a request with `If-None-Match`: the answer that the request named still holds.
  ///
  /// Diagnostics: each request leaves a breadcrumb of its method, its path template, and its status class. Each
  /// error is reported as its side asks (see `APIError`).
  private func answer<Response>(to endpoint: Endpoint<Response>) async throws(APIError) -> Answer<Response>? {
    do {
      return try await exchange(endpoint)
    } catch {
      diagnostics.report(error)
      throw error
    }
  }

  /// One request and its answer. Each way that it ends goes through `ended`, once.
  private func exchange<Response>(_ endpoint: Endpoint<Response>) async throws(APIError) -> Answer<Response>? {
    let route = endpoint.route
    // The log line, and the breadcrumb: the route and the status, never the address, the query, a header, or a
    // body.
    func ended(_ outcome: StaticString, status: Int? = nil) {
      Log.request(route, outcome, status: status)
      diagnostics.leave(.request(route, StatusClass(status: status)))
    }
    // A query parameter that the route doesn't name is never sent.
    let query = endpoint.query.filter { route.queryParameters.contains($0.name) }
    guard let url = instance.url(path: endpoint.path, query: query) else {
      ended("has no URL")
      throw .unreachable(.notTheAPI)
    }
    var request = URLRequest(url: url)
    request.httpMethod = route.method
    request.setValue(userAgent.text, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    // The token goes only to the instance address, on a route that needs a session.
    if let token, !route.isPublic { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let etag = endpoint.ifNoneMatch { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
    if let key = endpoint.idempotencyKey { request.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
    if let file = endpoint.file {
      request.httpBody = file
      request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    } else if let form = endpoint.form {
      let boundary = "wishbone-\(UUID().uuidString)"
      request.httpBody = Self.multipart(form, boundary: boundary)
      request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    } else if let body = endpoint.body {
      guard let data = try? await JSONCoding.encode(body) else { throw .undecodable(.init(route: route, keyPath: "")) }
      request.httpBody = data
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    let data: Data
    let answer: HTTPURLResponse
    do {
      // One time limit covers the request and its one resend.
      let (body, response) = try await withTimeout(timeout, clock: clock) { [request] in
        do {
          return try await Self.urlSession.data(for: request, delegate: NoRedirects())
        } catch let error as URLError where error.code == .networkConnectionLost && Self.isSafeToResend(request) {
          Log.request(route, "lost its connection, and is sent once more")
          return try await Self.urlSession.data(for: request, delegate: NoRedirects())
        }
      }
      guard let response = response as? HTTPURLResponse else {
        ended("is not HTTP")
        throw APIError.unreachable(.notTheAPI)
      }
      (data, answer) = (body, response)
    } catch let error as APIError {
      throw error
    } catch {
      if Task.isCancelled {
        ended("was cancelled")
        throw .cancelled
      }
      if let error = error as? URLError, Self.untrustedCertificate.contains(error.code) {
        ended("has a certificate that the device doesn't trust")
        throw .unreachable(.untrustedCertificate)
      }
      // Apart from the certificate codes above: no network, a timeout, a DNS failure, another TLS failure, a
      // connection that closed. All are unreachable, and the rule depends on no one code of `URLError`.
      ended(error is TimedOut ? "timed out" : "got no answer")
      throw .unreachable(.noAnswer)
    }

    let status = answer.statusCode
    let contentType = (answer.value(forHTTPHeaderField: "Content-Type") ?? "")
      .prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces).lowercased()
    switch status {
    case 204 where Response.self == NoContent.self:
      // A route that answers with no body. Its answer is the status alone.
      ended("ok", status: status)
      guard let none = NoContent() as? Response else { throw .undecodable(.init(route: route, keyPath: "")) }
      return Answer(body: none, etag: nil)
    case 200..<300:
      guard contentType == "application/json" else {
        ended("answer is not the API's", status: status)
        throw .unreachable(.notTheAPI)
      }
      do {
        let decoded = try await JSONCoding.decode(Response.self, from: data)
        ended("ok", status: status)
        return Answer(body: decoded, etag: answer.value(forHTTPHeaderField: "ETag"))
      } catch {
        let undecodable = APIError.Undecodable(route: route, keyPath: JSONCoding.keyPath(of: error))
        ended("answer can't be decoded", status: status)
        throw .undecodable(undecodable)
      }
    case 304 where endpoint.ifNoneMatch != nil:
      ended("not modified", status: status)
      return nil
    case 500..<600:
      ended("server error", status: status)
      throw .unreachable(.noAnswer)
    default:
      // Only the API's own answer counts: a problem with a code. A 401 from a reverse proxy, an access gateway, or
      // a captive portal is "unreachable", and so is a redirect.
      guard contentType == "application/problem+json",
        let problem = try? await JSONCoding.decode(Problem.self, from: data)
      else {
        ended("answer is not the API's", status: status)
        throw .unreachable(.notTheAPI)
      }
      let code = ErrorCode(problem.code)
      ended("refused", status: status)
      if status == 401, code == .unauthorized { throw .unauthorized }
      if status == 410, code == .apiVersionRemoved { throw .appTooOld }
      throw .refused(.init(route: route, status: status, code: code, detail: problem.detail, fields: problem.fields))
    }
  }

  /// A `multipart/form-data` body of text fields and files.
  private static func multipart(_ form: [FormField], boundary: String) -> Data {
    var body = Data()
    for field in form {
      switch field.value {
      case .text(let text):
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n".utf8))
        body.append(Data(text.utf8))
      case .file(let bytes, let filename, let contentType):
        body.append(
          Data(
            ("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field.name)\"; filename=\"\(filename)\"\r\n"
              + "Content-Type: \(contentType)\r\n\r\n").utf8))
        body.append(bytes)
      }
      body.append(Data("\r\n".utf8))
    }
    body.append(Data("--\(boundary)--\r\n".utf8))
    return body
  }

  /// Whether a write is safe to send once more when its connection was lost before its answer: it is idempotent by
  /// HTTP (`PUT`, `DELETE`, or `PATCH` with `If-Match`), or it carries an `Idempotency-Key`. A server or a reverse
  /// proxy closes an idle kept connection, and a request that goes on it at that moment is lost. `URLSession` sends
  /// a `GET` again by itself, on a new connection, but fails a write with `networkConnectionLost`. A write that is
  /// not safe to repeat, such as a redeem, is never sent again. See "Unreachable never ends the session" in
  /// `docs/spec.md`.
  private static func isSafeToResend(_ request: URLRequest) -> Bool {
    if request.value(forHTTPHeaderField: "Idempotency-Key") != nil { return true }
    switch request.httpMethod {
    case "PUT", "DELETE": return true
    case "PATCH": return request.value(forHTTPHeaderField: "If-Match") != nil
    default: return false
    }
  }

  /// The codes of `URLError` for a certificate that the device doesn't trust. Only these name the certificate:
  /// any other failure is unreachable with no answer.
  private static let untrustedCertificate: Set<URLError.Code> = [
    .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate,
    .serverCertificateNotYetValid,
  ]

  /// The one `URLSession` of every client. It keeps no cookie and no cache: the token is the session, and the
  /// local database is the copy.
  private static let urlSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: configuration)
  }()

  /// A redirect is never followed, so a request, and the token on it, never goes to another address. The answer
  /// that redirects is the answer, and it is not the API's own.
  private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
      _ session: URLSession,
      task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest,
      completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }
  }
}

/// The one place where JSON is encoded and decoded. It is never on the main actor.
enum JSONCoding {
  @concurrent
  static func decode<Value: Decodable & Sendable>(_ type: Value.Type, from data: Data) async throws -> Value {
    try JSONDecoder().decode(type, from: data)
  }

  @concurrent
  static func encode(_ value: any Encodable & Sendable) async throws -> Data {
    try JSONEncoder().encode(value)
  }

  /// The key path where a decode failed, such as `data[].title`. It names keys only, never a value.
  static func keyPath(of error: any Error) -> String {
    let path: [any CodingKey]
    switch error as? DecodingError {
    case .keyNotFound(let key, let context): path = context.codingPath + [key]
    case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
      path = context.codingPath
    default: path = []
    }
    return path.reduce(into: "") { text, key in
      if key.intValue != nil {
        text += "[]"
      } else {
        text += text.isEmpty ? key.stringValue : ".\(key.stringValue)"
      }
    }
  }
}
