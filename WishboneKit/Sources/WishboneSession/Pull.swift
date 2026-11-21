import WishboneAPI

/// One pull: it brings the copy up to date with what the session's user can see on the instance. See "When the
/// app syncs" in `docs/spec.md`, and "Versions of everything a caller sees" in the server's spec.
///
/// 1. It asks `GET /versions`, with the kept `ETag`. A 304 ends the pull: nothing changed.
/// 2. It compares the answer with the copy. An entry that is new, or that has another version, is fetched. A row
///    with no entry is removed: the thing was deleted, or moved out of view, or hidden, which look the same.
/// 3. A thing is fetched from its own address, or from its collection when that takes fewer requests.
/// 4. Each row is saved with the version that its own answer carried, and never with the one that the entry named.
/// 5. The answer's `ETag` is kept only when every fetch gave the version that its entry named. Otherwise none is
///    kept, and the next pull compares again.
///
/// **What the copy holds for now:** every user, group and occasion that the session's user can see, the
/// memberships that the user can read, the user's primary list, and the items on that list. Every other entry is
/// ignored. When the copy starts to hold another kind, `LocalDatabase.copySchema` rises.
///
/// **The order** is Home's data first: the users, the groups, the occasions, and the memberships. Then the items of
/// the primary list, and the list. So on the first sync, Home's rows are in the copy before any list is asked for.
///
/// **A summary and a membership have no answer that carries a version,** so step 4 can't hold for them. Each is
/// saved with the version that its entry named (see `PullPeople.swift`).
///
/// A pull writes each thing when its answer arrives. A pull that stops in the middle keeps what it wrote, and the
/// next pull fetches the rest.
struct Pull: Sendable {
  let client: APIClient
  let database: LocalDatabase

  /// The session's user.
  let userID: String

  /// Runs the pull. It throws the `APIError` of a request that gave no result, or the database's error.
  ///
  /// It returns the session's user as the copy has it when the pull ends. The instance has just said that this is
  /// the user's record: with the user's own answer, or with a version that the copy's row already had. That also
  /// holds for a pull that a 304 ended.
  ///
  /// An API's own 404 for `GET /versions` means an instance below the minimum server version. The pull stops
  /// there, and has changed nothing.
  @concurrent
  func run() async throws -> UserRow? {
    let answer = try await client.versions(ifNoneMatch: try await database.keptETag())
    guard case .changed(let versions) = answer else { return try await database.user(userID) }
    let named = Named(versions.entries)
    var agrees = true

    try await pullUsers(named, agrees: &agrees)
    try await pullGroups(named, agrees: &agrees)
    try await pullOccasions(named, agrees: &agrees)
    try await pullSummaries(named, agrees: &agrees)
    try await pullMemberships(named, agrees: &agrees)

    let user = try await database.user(userID)
    let listID = user?.record?.primaryListID
    // A list's own answer counts its items. So the items come first, and the list's answer is as new as theirs.
    try await pullItems(ofList: listID, named, agrees: &agrees)
    try await pullList(listID, named, agrees: &agrees)

    try await database.keep(etag: agrees ? versions.etag : nil)
    return user
  }

  /// What one answer of `GET /versions` names, for each kind that the copy holds: the version of each thing, by
  /// its ID.
  struct Named: Sendable {
    /// The users whom the session's user sees in full.
    var users: [String: String] = [:]

    /// The users whom the session's user gets only as a summary inside another resource.
    var summaries: [String: String] = [:]
    var groups: [String: String] = [:]
    var occasions: [String: String] = [:]
    var memberships: [MembershipRow.Key: String] = [:]
    var lists: [String: String] = [:]

    /// The items, by their list.
    var items: [String: [String: String]] = [:]

    init(_ entries: [ResourceVersion]) {
      for entry in entries {
        switch entry.kind {
        case .user: users[entry.id] = entry.version
        case .userSummary: summaries[entry.id] = entry.version
        case .group: groups[entry.id] = entry.version
        case .occasion: occasions[entry.id] = entry.version
        case .list: lists[entry.id] = entry.version
        case .item: if let listID = entry.listID { items[listID, default: [:]][entry.id] = entry.version }
        case .groupUsers: memberships[.init(kind: .groupUsers, ownerID: entry.id)] = entry.version
        case .usersInGroup: memberships[.init(kind: .usersInGroup, ownerID: entry.id)] = entry.version
        case .usersOfOccasion: memberships[.init(kind: .usersOfOccasion, ownerID: entry.id)] = entry.version
        case .groupGroups: memberships[.init(kind: .groupGroups, ownerID: entry.id)] = entry.version
        case .occasionGroups: memberships[.init(kind: .occasionGroups, ownerID: entry.id)] = entry.version
        // A kind that the app doesn't know is ignored.
        case .unknown: break
        }
      }
    }
  }

  // MARK: - One kind of resource

  /// Fetches the resources of one kind that the answer names with another version than the copy's rows have, and
  /// hands them to `save` as each answer arrives.
  ///
  /// - `named` and `rows` give the version of each resource, by its ID: as the answer names it, and as the copy
  ///   has it.
  /// - `all` reads the kind's collection, and `one` reads a resource from its own address.
  /// - `isHere` says whether a resource from its own address is still of this collection. For example, an item
  ///   that moved to another list is not.
  /// - `save` gets the rows to save, and the IDs of the rows to remove.
  ///
  /// The collection gives every resource of the kind, in as many requests as it has pages. A resource's own
  /// address gives one. For example, a reorder changes many items of one list, and one request gets them.
  func fetch<Resource: Sendable>(
    _ named: [String: String],
    not rows: [String: String],
    id: (Resource) -> String,
    isHere: (Resource) -> Bool = { _ in true },
    all: () async throws(APIError) -> Collection<Versioned<Resource>>,
    one: (String) async throws(APIError) -> Versioned<Resource>,
    agrees: inout Bool,
    save: (_ rows: [Versioned<Resource>], _ gone: [String]) async throws -> Void
  ) async throws {
    let changed = named.filter { rows[$0.key] != $0.value }.keys.sorted()
    guard !changed.isEmpty else { return }

    let pages = max(1, (named.count + APIClient.pageSize - 1) / APIClient.pageSize)
    guard changed.count > pages else {
      for id in changed {
        // A resource that left the collection between the two requests is gone from it.
        guard let resource = try await ifNotGone({ () async throws(APIError) in try await one(id) }),
          isHere(resource.resource)
        else {
          agrees = false
          if rows[id] != nil { try await save([], [id]) }
          continue
        }
        if resource.version != named[id] { agrees = false }
        try await save([resource], [])
      }
      return
    }

    let collection = try await all()
    // The collection is the kind as it is now. It can differ from what the answer named: a resource changed again,
    // came, or went, between the two requests.
    var now: [String: Versioned<Resource>] = [:]
    for resource in collection.rows {
      // A resource that came on two pages changed its place between them. The later page is the newer one.
      now[id(resource.resource)] = resource
    }
    if now.mapValues(\.version) != named { agrees = false }
    var fetched = now.values.filter { rows[id($0.resource)] != $0.version }
    var gone: [String] = []
    for id in named.keys.sorted() where now[id] == nil {
      if collection.isOnePage {
        // One page is one answer of the instance, so a resource that is not on it is gone.
        gone.append(id)
      } else if let resource = try await ifNotGone({ () async throws(APIError) in try await one(id) }),
        isHere(resource.resource)
      {
        // Between two pages, a resource can change its place in the collection's order, and be on neither. So
        // "named, and not in the collection" is no proof that it is gone. Its own address says.
        if rows[id] != resource.version { fetched.append(resource) }
      } else {
        gone.append(id)
      }
    }
    try await save(fetched, gone.filter { rows[$0] != nil })
  }

  // MARK: - The primary list

  /// Brings the items of the list up to date. With no list, the copy holds no item.
  private func pullItems(ofList listID: String?, _ named: Named, agrees: inout Bool) async throws {
    let items = listID.flatMap { named.items[$0] } ?? [:]
    let rows = try await database.itemVersions()
    let absent = rows.keys.filter { items[$0] == nil }
    if !absent.isEmpty { try await database.removeItems(absent) }
    guard let listID else { return }

    try await fetch(
      // A row that was just removed is no row: an item that is back when the fetch arrives is saved again.
      items, not: rows.filter { items[$0.key] != nil }, id: \.id,
      // An item that moved to another list between the two requests is gone from this one.
      isHere: { $0.listID == listID },
      all: { () async throws(APIError) in try await client.items(ofList: listID) },
      one: client.item,
      agrees: &agrees
    ) { items, gone in
      try await database.save(items, removingItems: gone)
    }
  }

  /// Brings the list up to date. The copy holds no other list.
  private func pullList(_ listID: String?, _ named: Named, agrees: inout Bool) async throws {
    let version = listID.flatMap { named.lists[$0] }
    let rows = try await database.listVersions()
    let absent = rows.keys.filter { $0 != listID || version == nil }
    if !absent.isEmpty { try await database.removeLists(absent) }

    guard let listID, let version, rows[listID] != version else { return }
    guard let list = try await ifNotGone({ () async throws(APIError) in try await client.list(listID) }) else {
      agrees = false
      if rows[listID] != nil { try await database.removeLists([listID]) }
      return
    }
    if list.version != version { agrees = false }
    try await database.save(list)
  }

  // MARK: - Things that went between two requests

  /// What a thing's own address gave. Nil for the API's own 404: the answer named the thing, and it went between
  /// the two requests. The pull removes its row, and goes on.
  ///
  /// Diagnostics: never. A 404 for something deleted elsewhere is not a fault.
  func ifNotGone<Answer>(_ fetch: () async throws(APIError) -> Answer) async throws(APIError) -> Answer? {
    do {
      return try await fetch()
    } catch .refused(let refusal) where refusal.status == 404 {
      return nil
    }
  }
}
