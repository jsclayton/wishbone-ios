/// The family that most tests start from. One call seeds it: `FixtureBuilder.standardFamily()`.
///
/// It has one of each case that the app must get right. See "Fixtures" in `docs/development.md`.
///
/// ```
/// Family (group) = { Household (group), relative }
/// Household      = { parent, child, deactivatedChild }
/// outsider       is in no group
/// ```
///
/// The server at the pinned release has no deletion requests, so the family has none yet.
public struct StandardFamily: Sendable {
  /// The instance's admin. The admin sees every user and every group, and no list through that access.
  public let admin: Fixture.Person

  /// The parent of both children.
  public let parent: Fixture.Person

  /// The parent's active child.
  public let child: Fixture.Person

  /// The parent's deactivated child. They have no session: only the admin, the parent, and the lists they are on
  /// still show them.
  public let deactivatedChild: Fixture.Person

  /// A user in `family`, and not in `household`: they see the household's users through the nesting. They gave
  /// `givenGift`.
  public let relative: Fixture.Person

  /// A user in no group, with no parent and no child. Only the admin's access shows them.
  public let outsider: Fixture.Person

  /// The inner group: the parent and both children.
  public let household: Fixture.Group

  /// The outer group: `household` nested in it, and the relative.
  public let family: Fixture.Group

  /// A shared occasion attached to `family`.
  public let groupOccasion: Fixture.Occasion

  /// A shared occasion marked everyone.
  public let everyoneOccasion: Fixture.Occasion

  public let blockedStore: Fixture.BlockedStore

  /// The deactivated child's primary list. `wantedItem` is on it.
  public let primaryList: Fixture.List

  /// An item on `primaryList` that nobody claimed.
  public let wantedItem: Fixture.Item

  /// The deactivated child's own extra list, with one item.
  public let extraList: Fixture.List

  /// An extra list that the deactivated child shares with another recipient, `child`. It has one item.
  public let sharedList: Fixture.List

  /// The parent's extra list. `pendingInvitation` is to it.
  public let parentList: Fixture.List

  /// The parent's invitation of the deactivated child to `parentList`. Nobody answered it.
  public let pendingInvitation: Fixture.Invitation

  /// A gift that the relative gave to the deactivated child, from `primaryList`. Its reveal has passed, so its
  /// item has left the list.
  public let givenGift: Fixture.Gift
}

extension FixtureBuilder {
  /// Seeds the standard family. A test that needs less calls the smaller builder methods, and a test that needs
  /// more adds to the family with them.
  public func standardFamily() async throws -> StandardFamily {
    let parent = try await person("Morgan", birthday: (3, 9))
    let child = try await person("Robin", birthday: (7, 21), parents: [parent])
    let soonDeactivated = try await person("Sam", birthday: (10, 2), parents: [parent])
    let relative = try await person("Jordan", birthday: (1, 30))
    let outsider = try await person("Casey", birthday: (5, 5))

    let household = try await group("Household", users: [parent, child, soonDeactivated])
    let family = try await group("Family", users: [relative], groups: [household])
    let groupOccasion = try await sharedOccasion("Reunion", month: 8, day: 1, groups: [family])
    let everyoneOccasion = try await sharedOccasion("Holiday", month: 12, day: 25, isEveryone: true)
    let blockedStore = try await blockedStore()

    // The child makes their lists, and gets their invitation and their gift, while they are active. A deactivated
    // user can do none of it, and nobody can do it for them.
    let primaryList = try await primaryList(of: soonDeactivated)
    let wantedItem = try await item("Kite", on: primaryList, as: soonDeactivated)
    let givenItem = try await item("Puzzle", on: primaryList, as: soonDeactivated)
    let extraList = try await list("Camping", of: soonDeactivated)
    _ = try await item("Tent", on: extraList, as: soonDeactivated)
    let sharedList = try await list("Our room", of: soonDeactivated)
    try await accept(try await invite(child, to: sharedList, as: soonDeactivated))
    _ = try await item("Bunk bed", on: sharedList, as: child)
    let parentList = try await list("Our house", of: parent)
    let pendingInvitation = try await invite(soonDeactivated, to: parentList, as: parent)
    let givenGift = try await claim(givenItem, as: relative, fromLabel: "The cousins")
    try await reveal(giftsFor: soonDeactivated)

    let deactivatedChild = try await deactivate(soonDeactivated)
    return StandardFamily(
      admin: admin,
      parent: parent,
      child: child,
      deactivatedChild: deactivatedChild,
      relative: relative,
      outsider: outsider,
      household: household,
      family: family,
      groupOccasion: groupOccasion,
      everyoneOccasion: everyoneOccasion,
      blockedStore: blockedStore,
      primaryList: primaryList,
      wantedItem: wantedItem,
      extraList: extraList,
      sharedList: sharedList,
      parentList: parentList,
      pendingInvitation: Fixture.Invitation(id: pendingInvitation.id, list: parentList, invited: deactivatedChild),
      givenGift: givenGift
    )
  }
}
