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
/// **What the copy holds for now:** the session's user, the user's primary list, and the items on that list.
/// Every other entry is ignored. When the copy starts to hold another kind, `LocalDatabase.copySchema` rises.
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
    var agrees = true

    let user = try await pullUser(named: versions.entries, agrees: &agrees)
    // A list's own answer counts its items. So the items come first, and the list's answer is as new as theirs.
    try await pullItems(ofList: user?.primaryListID, named: versions.entries, agrees: &agrees)
    try await pullList(user?.primaryListID, named: versions.entries, agrees: &agrees)

    try await database.keep(etag: agrees ? versions.etag : nil)
    return user
  }

  /// Brings the session's user up to date, and returns the user's row. Nil when the answer names no such user.
  private func pullUser(named entries: [ResourceVersion], agrees: inout Bool) async throws -> UserRow? {
    let row = try await database.user(userID)
    guard let entry = entries.first(where: { $0.kind == .user && $0.id == userID }) else {
      if row != nil { try await database.removeUser(userID) }
      return nil
    }
    if row?.version == entry.version { return row }
    guard let user = try await ifNotGone({ () async throws(APIError) in try await client.me() }) else {
      agrees = false
      if row != nil { try await database.removeUser(userID) }
      return nil
    }
    if user.version != entry.version { agrees = false }
    return try await database.save(user)
  }

  /// Brings the items of the list up to date. With no list, the copy holds no item.
  private func pullItems(ofList listID: String?, named entries: [ResourceVersion], agrees: inout Bool) async throws {
    var named: [String: String] = [:]
    if let listID {
      for entry in entries where entry.kind == .item && entry.listID == listID {
        named[entry.id] = entry.version
      }
    }
    var rows = try await database.itemVersions()
    let absent = rows.keys.filter { named[$0] == nil }
    if !absent.isEmpty {
      try await database.removeItems(absent)
      rows = rows.filter { named[$0.key] != nil }
    }

    let changed = named.filter { rows[$0.key] != $0.value }.keys.sorted()
    guard let listID, !changed.isEmpty else { return }

    // The collection gives every item of the list, in as many requests as it has pages. An item's own address
    // gives one. For example, a reorder changes many items of one list, and one request gets them.
    let pages = max(1, (named.count + APIClient.pageSize - 1) / APIClient.pageSize)
    if changed.count > pages {
      let items = try await client.items(ofList: listID)
      // The collection is the list as it is now. It can differ from what the entries named: an item changed
      // again, came, or went, between the two requests.
      let now = Dictionary(items.map { ($0.resource.id, $0.version) }, uniquingKeysWith: { _, last in last })
      if now != named { agrees = false }
      try await database.save(
        items.filter { rows[$0.resource.id] != $0.version },
        removingItems: named.keys.filter { now[$0] == nil && rows[$0] != nil })
      return
    }

    for id in changed {
      let item = try await ifNotGone({ () async throws(APIError) in try await client.item(id) })
      // An item that moved to another list between the two requests is gone from this one.
      guard let item, item.resource.listID == listID else {
        agrees = false
        if rows[id] != nil { try await database.removeItems([id]) }
        continue
      }
      if item.version != named[id] { agrees = false }
      try await database.save([item])
    }
  }

  /// Brings the list up to date. The copy holds no other list.
  private func pullList(_ listID: String?, named entries: [ResourceVersion], agrees: inout Bool) async throws {
    let entry = listID.flatMap { id in entries.first { $0.kind == .list && $0.id == id } }
    let rows = try await database.listVersions()
    let absent = rows.keys.filter { $0 != entry?.id }
    if !absent.isEmpty { try await database.removeLists(absent) }

    guard let entry, rows[entry.id] != entry.version else { return }
    guard let list = try await ifNotGone({ () async throws(APIError) in try await client.list(entry.id) }) else {
      agrees = false
      if rows[entry.id] != nil { try await database.removeLists([entry.id]) }
      return
    }
    if list.version != entry.version { agrees = false }
    try await database.save(list)
  }

  /// What a thing's own address gave. Nil for the API's own 404: the entries named the thing, and it went between
  /// the two requests. The pull removes its row, and goes on.
  ///
  /// Diagnostics: never. A 404 for something deleted elsewhere is not a fault.
  private func ifNotGone<Resource>(
    _ fetch: () async throws(APIError) -> Versioned<Resource>
  ) async throws(APIError) -> Versioned<Resource>? {
    do {
      return try await fetch()
    } catch .refused(let refusal) where refusal.status == 404 {
      return nil
    }
  }
}
