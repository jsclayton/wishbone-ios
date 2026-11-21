import WishboneAPI

// The pull of the gifts and of the blocked stores. See `Pull`.
//
// **The gifts are Home's data,** because Home's countdown counts them. So the pull asks for them with the users,
// the groups and the occasions, before any list. A gift is kept as the server sends it to the session's user: a
// giver's open gift has the giver's own fields, and a recipient's given gift has none of them. An open gift is
// never sent to its recipients, so their copy never has it.
//
// **The blocked stores are not in `GET /versions`.** The answer doesn't cover them, so a 304 says nothing about
// them. Each pull of the admin reads the whole collection again, and it takes the place of what the copy holds.

extension Pull {
  // MARK: - Gifts

  /// Brings the gifts up to date: the ones that the session's user gives, and the given gifts for them or their
  /// children. A gift's giver, its recipients and the users in its flags are saved from its body, as summaries.
  func pullGifts(_ named: Named, agrees: inout Bool) async throws {
    let rows = try await database.giftVersions()
    try await fetch(
      named.gifts, not: rows, id: \.id, all: client.gifts, one: client.gift, agrees: &agrees
    ) { gifts, gone in
      try await database.save(gifts, summaries: named.summaries, removingGifts: gone)
    }
  }

  // MARK: - Blocked stores

  /// Brings the blocked stores up to date, for the admin only. Anyone else sends no request, and has none in the
  /// copy.
  ///
  /// The session's user is the admin when the copy says so. The pull has just brought the user's record up to
  /// date, or `GET /versions` has just said that it is current.
  func pullBlockedStores() async throws {
    guard try await database.user(userID)?.record?.isAdmin == true else {
      if try await database.holdsBlockedStores() { try await database.replaceBlockedStores(with: []) }
      return
    }
    try await database.replaceBlockedStores(with: try await client.blockedStores().rows)
  }
}
