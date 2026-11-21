import WishboneAPI

// The pull of Home's data: the users, the groups, the occasions, and the memberships, and the summaries that are
// left at the end of the pull. See `Pull`.
//
// **Two things have no answer that carries a version:** a user whom the session's user gets only as a summary,
// and a membership. `GET /versions` gives each a version, which is a hash that the app can't make. So each is
// saved with the version that its entry named, and the pull can't tell one that changed between the two requests.
// Such a row is then newer than its version says. The next answer of `GET /versions` names another version for
// it, and it is fetched again.

extension Pull {
  // MARK: - Users

  /// Brings the users up to date: the ones that the session's user sees in full.
  ///
  /// A user who is no longer named in full, and is named as a summary, is a summary by now: the removal at the
  /// start of the pull kept the name and the avatar, and dropped the rest. The summary's body didn't change, so no
  /// body that holds it is fetched.
  func pullUsers(_ named: Named, agrees: inout Bool) async throws {
    let rows = try await database.userVersions()
    try await fetch(
      named.users, not: rows.full, id: \.id, all: client.users, one: client.user, agrees: &agrees
    ) { users, gone in
      try await database.save(users, summaries: named.summaries, removingUsers: gone)
    }
  }

  /// Brings the summaries up to date: the users whom the session's user gets only inside another resource.
  ///
  /// A summary has no address. It is saved from each body that contains it, in the change that saves the body
  /// (see `LocalDatabase.save`). When a summary changes, the server gives every resource that contains it a new
  /// version, so the pull has fetched such a body by now. This step is for a summary that is left: the answer
  /// names it with another version than the copy has, or the copy has none. It runs after every other step, so
  /// every body that the copy holds is in it.
  ///
  /// - A body of the copy contains it: that body is fetched again, from its own address, or from the list's
  ///   recipients for a recipient row. This happens only after a body arrived newer than the answer named it.
  /// - No body of the copy contains it: only a body that the copy doesn't hold contains it, such as one of a kind
  ///   that the app doesn't know. It is ignored, as that body is, and a row that the copy has for it goes. That
  ///   row is older than the answer, and the answer's `ETag` is kept, so nothing would ever bring the new summary.
  func pullSummaries(_ named: Named, agrees: inout Bool) async throws {
    let rows = try await database.userVersions()
    let left = Set(named.summaries.filter { rows.summaries[$0.key] != $0.value && rows.full[$0.key] == nil }.keys)
    guard !left.isEmpty else { return }
    let naming = try await database.bodiesNaming(left)
    let unheld = left.filter { naming[$0] == nil && rows.summaries[$0] != nil }.sorted()
    if !unheld.isEmpty { try await database.removeSummaries(unheld) }
    guard !naming.isEmpty else { return }

    for body in Set(naming.values).sorted(by: { $0.key < $1.key }) {
      try await fetchAgain(body, named, agrees: &agrees)
    }
    let settled = try await database.userVersions().summaries
    if naming.keys.contains(where: { settled[$0] != named.summaries[$0] }) { agrees = false }
  }

  /// A body of the copy that contains a summary, or a store link.
  enum Body: Hashable, Sendable {
    case user(String)
    case occasion(String)
    case list(String)
    case recipients(ofList: String)
    case item(String)
    case invitation(String)
    case gift(String)

    /// A key that sorts the bodies, so that the requests go in one order.
    var key: String {
      switch self {
      case .user(let id): "user \(id)"
      case .occasion(let id): "occasion \(id)"
      case .list(let id): "list \(id)"
      case .recipients(let listID): "recipients \(listID)"
      case .item(let id): "item \(id)"
      case .invitation(let id): "invitation \(id)"
      case .gift(let id): "gift \(id)"
      }
    }
  }

  /// Fetches a body of the copy again, and saves it, with the summaries and the store links that it contains. A
  /// body that went between the two requests is removed.
  func fetchAgain(_ body: Body, _ named: Named, agrees: inout Bool) async throws {
    let summaries = named.summaries
    switch body {
    case .user(let id):
      guard let user = try await ifNotGone({ () async throws(APIError) in try await client.user(id) }) else {
        agrees = false
        return try await database.save([Versioned<User>](), removingUsers: [id])
      }
      if user.version != named.users[id] { agrees = false }
      try await database.save([user], summaries: summaries)
    case .occasion(let id):
      guard let occasion = try await ifNotGone({ () async throws(APIError) in try await client.occasion(id) }) else {
        agrees = false
        return try await database.save([Versioned<Occasion>](), removingOccasions: [id])
      }
      if occasion.version != named.occasions[id] { agrees = false }
      try await database.save([occasion], summaries: summaries)
    case .list(let id):
      guard let list = try await ifNotGone({ () async throws(APIError) in try await client.list(id) }) else {
        agrees = false
        return try await database.removeList(id)
      }
      if list.version != named.lists[id] { agrees = false }
      try await database.save([list], summaries: summaries)
    case .recipients(let listID):
      try await pullRecipients(ofList: listID, named, always: true, agrees: &agrees)
    case .item(let id):
      guard let item = try await ifNotGone({ () async throws(APIError) in try await client.item(id) }) else {
        agrees = false
        return try await database.save([Versioned<Item>](), removingItems: [id])
      }
      if item.version != named.itemsByID[id] { agrees = false }
      try await database.save([item], storeLinks: named.storeLinks, summaries: summaries)
    case .invitation(let id):
      guard let invitation = try await ifNotGone({ () async throws(APIError) in try await client.invitation(id) })
      else {
        agrees = false
        return try await database.save([Versioned<Invitation>](), removingInvitations: [id])
      }
      if invitation.version != named.invitations[id] { agrees = false }
      try await database.save([invitation], summaries: summaries)
    case .gift(let id):
      guard let gift = try await ifNotGone({ () async throws(APIError) in try await client.gift(id) }) else {
        agrees = false
        return try await database.save([Versioned<Gift>](), removingGifts: [id])
      }
      if gift.version != named.gifts[id] { agrees = false }
      try await database.save([gift], summaries: summaries)
    }
  }

  // MARK: - Groups and occasions

  /// Brings the groups up to date.
  func pullGroups(_ named: Named, agrees: inout Bool) async throws {
    let rows = try await database.groupVersions()
    try await fetch(
      named.groups, not: rows, id: \.id, all: client.groups, one: client.group, agrees: &agrees
    ) { groups, gone in
      try await database.save(groups, removingGroups: gone)
    }
  }

  /// Brings the occasions up to date.
  func pullOccasions(_ named: Named, agrees: inout Bool) async throws {
    let rows = try await database.occasionVersions()
    try await fetch(
      named.occasions, not: rows, id: \.id, all: client.occasions, one: client.occasion, agrees: &agrees
    ) { occasions, gone in
      try await database.save(occasions, summaries: named.summaries, removingOccasions: gone)
    }
  }

  // MARK: - Memberships

  /// Brings the memberships up to date. Each is the IDs that its collection gives, in the server's order.
  ///
  /// **The answer has an entry only for a membership that the session's user can read.** So the copy has a row
  /// only for those, and a membership with no entry gets no row. The absence is never saved as "no members".
  ///
  /// **A birthday or a custom occasion applies to its own user, and to nobody else.** The copy takes that user
  /// from the occasion's row, and sends no request. Only the users of a shared occasion are fetched.
  func pullMemberships(_ named: Named, agrees: inout Bool) async throws {
    let rows = try await database.membershipVersions()
    var changed = named.memberships.filter { rows[$0.key] != $0.value }

    let users = try await database.usersOfOwnOccasions()
    var own: [MembershipRow] = []
    for (key, version) in changed where key.kind == .usersOfOccasion {
      guard let userID = users[key.ownerID] else { continue }
      own.append(MembershipRow(kind: key.kind, ownerID: key.ownerID, memberIDs: [userID], version: version))
      changed[key] = nil
    }
    if !own.isEmpty { try await database.save(own) }

    let order = MembershipRow.Kind.allCases
    let keys = changed.keys.sorted { first, second in
      let places = (order.firstIndex(of: first.kind) ?? 0, order.firstIndex(of: second.kind) ?? 0)
      return places.0 != places.1 ? places.0 < places.1 : first.ownerID < second.ownerID
    }
    for key in keys {
      guard let version = changed[key] else { continue }
      guard let members = try await ifReadable({ () async throws(APIError) in try await members(of: key) }) else {
        // The group or the occasion went between the two requests, or the user may no longer read its members.
        agrees = false
        if rows[key] != nil { try await database.save([], removingMemberships: [key]) }
        continue
      }
      try await database.save([
        MembershipRow(kind: key.kind, ownerID: key.ownerID, memberIDs: members, version: version)
      ])
    }
  }

  /// The members of a membership, from its collection.
  private func members(of key: MembershipRow.Key) async throws(APIError) -> [String] {
    switch key.kind {
    case .groupUsers: try await client.userIDs(directlyInGroup: key.ownerID)
    case .usersInGroup: try await client.userIDs(inGroup: key.ownerID)
    case .usersOfOccasion: try await client.userIDs(ofOccasion: key.ownerID)
    case .groupGroups: try await client.groupIDs(directlyInGroup: key.ownerID)
    case .occasionGroups: try await client.groupIDs(ofOccasion: key.ownerID)
    }
  }

  /// What a membership's collection gave. Nil for the API's own 404, and for its 403: the session's user can't
  /// read the collection now.
  ///
  /// Diagnostics: never. Neither answer is a fault.
  private func ifReadable<Answer>(_ fetch: () async throws(APIError) -> Answer) async throws(APIError) -> Answer? {
    do {
      return try await fetch()
    } catch .refused(let refusal) where refusal.status == 404 || refusal.status == 403 {
      return nil
    }
  }
}
