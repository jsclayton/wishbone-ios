import WishboneAPI

// The pull of the lists: every list that the session's user can see, with its items, their store links, and its
// recipient rows, and then the invitations. See `Pull`.
//
// **The order:** the lists that the user is a recipient of come first, the primary list first, and then everyone
// else's. For each part, the items and the recipient rows of each list come first, and then the lists. A list's
// own answer counts its items, so it is as new as theirs. The session model publishes a list's items only with the
// list, so the two show in the same change.
//
// **A store link has no answer that the app reads.** It comes inside its item's body, in the order that the
// server gives the session's user, and is saved with the item, with the version that its entry named. A change to
// a store link changes its item's version, so the pull has fetched the item by then. `pullStoreLinks` is for a
// store link that is left: its item arrived newer than the answer named it.
//
// **Claim state is kept as the server sends it.** A recipient never gets `still_wanted` or `my_claimed_quantity`,
// so their copy never has them. A giver no longer sees an item that others claimed in full: it is absent from the
// answer, and the removal at the start of the pull takes it out.

extension Pull {
  // MARK: - Lists

  /// Brings the lists up to date: the user's own first, and then everyone else's.
  ///
  /// The answer names the user's own lists by their recipient rows: a list with a row of the session's user.
  func pullLists(_ named: Named, primaryListID: String?, agrees: inout Bool) async throws {
    let own = Set(named.lists.keys.filter { named.recipients[$0]?[userID] != nil })
    let order = { (ids: [String]) in
      ids.sorted { first, second in
        if first == primaryListID { return second != primaryListID }
        return second != primaryListID && first < second
      }
    }
    let parts = [
      order(Array(own)), order(named.lists.keys.filter { !own.contains($0) }),
    ]
    for (index, part) in parts.enumerated() where !part.isEmpty {
      var here: [String] = []
      for listID in part {
        guard try await pullItems(ofList: listID, named, agrees: &agrees),
          try await pullRecipients(ofList: listID, named, agrees: &agrees)
        else { continue }
        here.append(listID)
      }
      try await pullListRows(here, isOwn: index == 0, own: own, named, agrees: &agrees)
    }
  }

  /// Brings the rows of the lists with the IDs up to date.
  ///
  /// The collection is every list that the user can see. Only the lists of this part are taken from it: the
  /// user's own, or everyone else's.
  private func pullListRows(
    _ ids: [String],
    isOwn: Bool,
    own: Set<String>,
    _ named: Named,
    agrees: inout Bool
  ) async throws {
    let part = named.lists.filter { ids.contains($0.key) }
    let rows = try await database.listVersions()
    try await fetch(
      part, not: rows.filter { part[$0.key] != nil }, id: \.id,
      all: { () async throws(APIError) in
        let lists = try await client.lists()
        // A list that came between the two requests is in no part of the answer. It is saved with everyone
        // else's.
        let here = lists.rows.filter { isOwn ? part[$0.resource.id] != nil : !own.contains($0.resource.id) }
        return FetchedCollection(rows: here, isOnePage: lists.isOnePage)
      },
      one: client.list,
      agrees: &agrees
    ) { lists, gone in
      try await database.save(lists, summaries: named.summaries, removingLists: gone)
    }
  }

  // MARK: - Items

  /// Brings the items of the list up to date, with their store links. False when the list went between two
  /// requests: its collection answered the API's own 404, and the list is out of the copy, with its items.
  ///
  /// An item that moved here from another list keeps its ID: the answer names it on this list, with a new
  /// version, so it is fetched, and its row now has this list.
  private func pullItems(ofList listID: String, _ named: Named, agrees: inout Bool) async throws -> Bool {
    let items = named.items[listID] ?? [:]
    let rows = try await database.itemVersions()
    do {
      try await fetch(
        items, not: rows.filter { items[$0.key] != nil }, id: \.id,
        all: { () async throws(APIError) in try await client.items(ofList: listID) },
        one: client.item,
        agrees: &agrees
      ) { items, gone in
        try await database.save(
          items, storeLinks: named.storeLinks, summaries: named.summaries, removingItems: gone)
      }
      return true
    } catch APIError.refused(let refusal) where refusal.status == 404 {
      // Diagnostics: never. A list deleted elsewhere is not a fault.
      agrees = false
      try await database.removeList(listID)
      return false
    }
  }

  /// Brings the store links that are left up to date: the answer names them with another version than the copy
  /// has, or the copy has none. Each item that has one is fetched again, from its own address.
  func pullStoreLinks(_ named: Named, agrees: inout Bool) async throws {
    let rows = try await database.storeLinkVersions()
    let left = named.storeLinks.filter { rows[$0.key] != $0.value }.keys
    let items = Set(left.compactMap { named.storeLinkItems[$0] }).filter { named.itemsByID[$0] != nil }
    let held = try await database.itemVersions()
    for id in items.sorted() where held[id] != nil {
      try await fetchAgain(.item(id), named, agrees: &agrees)
    }
    if try await database.storeLinkVersions() != named.storeLinks { agrees = false }
  }

  // MARK: - Recipients

  /// Brings the list's recipient rows up to date. A recipient has no address of its own, so a changed one is read
  /// from the list's recipients. `always` reads them even when no row changed. False when the list went between
  /// two requests, as for `pullItems`.
  @discardableResult
  func pullRecipients(
    ofList listID: String,
    _ named: Named,
    always: Bool = false,
    agrees: inout Bool
  ) async throws -> Bool {
    let recipients = named.recipients[listID] ?? [:]
    let rows = try await database.recipientVersions()[listID] ?? [:]
    guard always || recipients.contains(where: { rows[$0.key] != $0.value }) else { return true }

    let fetched = try await ifNotGone { () async throws(APIError) in try await client.recipients(ofList: listID) }
    guard let collection = fetched else {
      agrees = false
      try await database.removeList(listID)
      return false
    }
    var now: [String: Versioned<Recipient>] = [:]
    for row in collection.rows {
      now[row.resource.user.id] = row
    }
    if now.mapValues(\.version) != recipients { agrees = false }
    // A row that is not on the one page of the collection is gone. Between two pages, nothing says so, and the
    // row stays until the next pull.
    let gone = collection.isOnePage ? rows.keys.filter { now[$0] == nil }.sorted() : []
    try await database.save(
      now.values.filter { rows[$0.resource.user.id] != $0.version }, ofList: listID, summaries: named.summaries,
      removingRecipients: gone)
    return true
  }

  // MARK: - Invitations

  /// Brings the pending invitations up to date. An invitation keeps its list's name: the invited user can't see
  /// the list yet.
  func pullInvitations(_ named: Named, agrees: inout Bool) async throws {
    let rows = try await database.invitationVersions()
    try await fetch(
      named.invitations, not: rows, id: \.id, all: client.invitations, one: client.invitation, agrees: &agrees
    ) { invitations, gone in
      try await database.save(invitations, summaries: named.summaries, removingInvitations: gone)
    }
  }
}
