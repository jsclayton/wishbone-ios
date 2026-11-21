import WishboneAPI

// The pull of Home's data: the users, the groups, the occasions, and the memberships. See `Pull`.
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
  /// A user who is no longer named in full, and is named as a summary, stays as a summary: the name and the
  /// avatar stay, and the rest goes. The summary's body didn't change, so no body that holds it is fetched.
  func pullUsers(_ named: Named, agrees: inout Bool) async throws {
    let rows = try await database.userVersions()
    var summaries: [String: String] = [:]
    var gone = rows.summaries.keys.filter { named.summaries[$0] == nil && named.users[$0] == nil }
    for id in rows.full.keys where named.users[id] == nil {
      if let version = named.summaries[id] { summaries[id] = version } else { gone.append(id) }
    }
    if !summaries.isEmpty || !gone.isEmpty {
      try await database.keepAsSummaries(summaries, removingUsers: gone)
    }

    // A row that was just removed, or made a summary, is no row in full any more.
    let kept = rows.full.filter { named.users[$0.key] != nil }
    try await fetch(
      named.users, not: kept, id: \.id, all: client.users, one: client.user, agrees: &agrees
    ) { users, gone in
      try await database.save(users, summaries: named.summaries, removingUsers: gone)
    }
  }

  /// Brings the summaries up to date: the users whom the session's user gets only inside another resource.
  ///
  /// A summary has no address. It is saved from each body that contains it, in the change that saves the body
  /// (see `LocalDatabase.save`). When a summary changes, the server gives every resource that contains it a new
  /// version, so the pull has fetched such a body by now. This step is for a summary that is left: the answer
  /// names it with another version than the copy has, or the copy has none.
  ///
  /// - A user of the copy names it as a parent or a child: that user's body contains it, and is fetched from its
  ///   own address. This happens only after a body arrived newer than the answer named it.
  /// - No row of the copy names it: only a kind that the copy doesn't hold yet contains it, such as a list's
  ///   recipients. It is ignored, as that kind is.
  func pullSummaries(_ named: Named, agrees: inout Bool) async throws {
    let rows = try await database.userVersions()
    let left = Set(named.summaries.filter { rows.summaries[$0.key] != $0.value && rows.full[$0.key] == nil }.keys)
    guard !left.isEmpty else { return }
    let naming = try await database.usersNaming(left)
    guard !naming.isEmpty else { return }

    for id in Set(naming.values).sorted() {
      guard let user = try await ifNotGone({ () async throws(APIError) in try await client.user(id) }) else {
        agrees = false
        try await database.save([], removingUsers: [id])
        continue
      }
      if user.version != named.users[id] { agrees = false }
      try await database.save([user], summaries: named.summaries)
    }
    let settled = try await database.userVersions().summaries
    if naming.keys.contains(where: { settled[$0] != named.summaries[$0] }) { agrees = false }
  }

  // MARK: - Groups and occasions

  /// Brings the groups up to date.
  func pullGroups(_ named: Named, agrees: inout Bool) async throws {
    let rows = try await database.groupVersions()
    let absent = rows.keys.filter { named.groups[$0] == nil }
    if !absent.isEmpty { try await database.save([Versioned<Group>](), removingGroups: absent) }

    let kept = rows.filter { named.groups[$0.key] != nil }
    try await fetch(
      named.groups, not: kept, id: \.id, all: client.groups, one: client.group, agrees: &agrees
    ) { groups, gone in
      try await database.save(groups, removingGroups: gone)
    }
  }

  /// Brings the occasions up to date.
  func pullOccasions(_ named: Named, agrees: inout Bool) async throws {
    let rows = try await database.occasionVersions()
    let absent = rows.keys.filter { named.occasions[$0] == nil }
    if !absent.isEmpty { try await database.save([Versioned<Occasion>](), removingOccasions: absent) }

    let kept = rows.filter { named.occasions[$0.key] != nil }
    try await fetch(
      named.occasions, not: kept, id: \.id, all: client.occasions, one: client.occasion, agrees: &agrees
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
    let absent = rows.keys.filter { named.memberships[$0] == nil }
    var changed = named.memberships.filter { rows[$0.key] != $0.value }

    let users = try await database.usersOfOwnOccasions()
    var own: [MembershipRow] = []
    for (key, version) in changed where key.kind == .usersOfOccasion {
      guard let userID = users[key.ownerID] else { continue }
      own.append(MembershipRow(kind: key.kind, ownerID: key.ownerID, memberIDs: [userID], version: version))
      changed[key] = nil
    }
    if !absent.isEmpty || !own.isEmpty { try await database.save(own, removingMemberships: absent) }

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
