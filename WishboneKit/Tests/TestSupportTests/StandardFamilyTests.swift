import Foundation
import TestSupport
import Testing

@Suite("The standard family", .timeLimit(.minutes(1)))
struct StandardFamilyTests {
  /// The IDs in one page of a collection. Each use is of a collection that holds one family's rows only.
  private func ids(_ collection: JSON) -> Set<String> {
    Set((collection["data"].array ?? []).compactMap { $0["id"].string })
  }

  @Test("One call seeds the standard family, and each person reads it back through their own bearer session")
  func seedsAndReadsBack() async throws {
    let server = try await TestServer.shared()
    let builder = try await FixtureBuilder(server: server)
    let family = try await builder.standardFamily()
    let everyone = [
      family.admin, family.parent, family.child, family.deactivatedChild, family.relative, family.outsider,
    ]

    // Each person who can sign in has a session of their own, on this server.
    for person in everyone where person.id != family.deactivatedChild.id {
      let session = try person.signedIn()
      let me = try await session.get("/users/me")
      #expect(me["id"].string == person.id)
      #expect(me["name"].string == person.name)
      #expect(session.instance == server.address)
    }
    #expect(Set(everyone.map(\.id)).count == everyone.count)
    #expect(Set(everyone.compactMap { $0.session?.token }).count == everyone.count - 1)

    // The names are this test's own.
    for person in everyone where person.id != family.admin.id {
      #expect(person.name.hasSuffix(builder.tag))
    }

    /// The people of the family that the person can see, by asking for each one.
    func seen(by person: Fixture.Person) async throws -> Set<String> {
      var seen: Set<String> = []
      for other in everyone where try await person.signedIn().status(of: "/users/\(other.id)") == 200 {
        seen.insert(other.id)
      }
      return seen
    }
    func ids(of people: Fixture.Person...) -> Set<String> {
      Set(people.map(\.id))
    }

    // The admin sees every user, the outsider too. Nobody else sees the outsider, and the outsider sees nobody.
    #expect(try await seen(by: family.admin) == Set(everyone.map(\.id)))
    #expect(try await seen(by: family.outsider) == ids(of: family.outsider))
    // A deactivated user shows only to the admin and to their parent.
    #expect(
      try await seen(by: family.parent)
        == ids(of: family.parent, family.child, family.deactivatedChild, family.relative))
    #expect(try await seen(by: family.child) == ids(of: family.parent, family.child, family.relative))
    // The relative sees the household through the nesting of the groups.
    #expect(try await seen(by: family.relative) == ids(of: family.parent, family.child, family.relative))

    try await readsBackAsTheAdmin(family)
    try await readsBackAsTheParent(family)
    try await readsBackAsTheChild(family)
    try await readsBackAsTheRelative(family)
    try await readsBackAsTheOutsider(family)
  }

  private func readsBackAsTheAdmin(_ family: StandardFamily) async throws {
    let admin = try family.admin.signedIn()
    let deactivated = try await admin.get("/users/\(family.deactivatedChild.id)")
    #expect(!deactivated["deactivated_at"].isNull)
    #expect(deactivated["parents"][0]["id"].string == family.parent.id)
    #expect(deactivated["can_reactivate"] == true)
    // A deactivated user can't sign in, and nobody can make them a login link.
    let link = try await admin.send("POST", "/users/\(family.deactivatedChild.id)/login-links")
    #expect(link.status == 403)
    #expect(try link.json["code"] == "user_deactivated")

    // The groups, and their nesting.
    #expect(ids(try await admin.get("/groups/\(family.family.id)/groups")) == [family.household.id])
    #expect(ids(try await admin.get("/groups/\(family.family.id)/users")) == [family.relative.id])
    #expect(
      ids(try await admin.get("/groups/\(family.household.id)/users"))
        == [family.parent.id, family.child.id, family.deactivatedChild.id]
    )

    // The shared occasions: one on the outer group, and one for everyone.
    #expect(ids(try await admin.get("/occasions/\(family.groupOccasion.id)/groups")) == [family.family.id])
    #expect(try await admin.get("/occasions/\(family.groupOccasion.id)")["is_everyone"] == false)
    #expect(try await admin.get("/occasions/\(family.everyoneOccasion.id)")["is_everyone"] == true)

    // Only the admin sees the blocked stores.
    let stores = try await admin.all("/blocked-stores")
    #expect(
      stores.contains { $0["id"].string == family.blockedStore.id && $0["store"].string == family.blockedStore.store })
    #expect(try await family.parent.signedIn().send("GET", "/blocked-stores").status == 403)

    // The admin's access shows no list.
    #expect(try await admin.status(of: "/lists/\(family.primaryList.id)") == 404)
  }

  private func readsBackAsTheParent(_ family: StandardFamily) async throws {
    let parent = try family.parent.signedIn()
    #expect(try await parent.get("/users/me")["children"].array?.count == 2)

    // The deactivated child's lists: the parent sees all three, and can edit none while the child is deactivated.
    let lists = try await parent.get("/lists?recipient_id=\(family.deactivatedChild.id)")
    #expect(ids(lists) == [family.primaryList.id, family.extraList.id, family.sharedList.id])
    #expect(try await parent.get("/lists/\(family.primaryList.id)")["is_primary"] == true)
    #expect(try await parent.get("/lists/\(family.extraList.id)")["can_edit"] == false)

    // The primary list keeps the item that nobody claimed. The given item has left it.
    #expect(ids(try await parent.get("/lists/\(family.primaryList.id)/items")) == [family.wantedItem.id])
    #expect(try await parent.get("/lists/\(family.extraList.id)")["item_count"] == 1)

    // The shared list has both children, and the parent edits it through the active one.
    let shared = try await parent.get("/lists/\(family.sharedList.id)")
    #expect(
      Set((shared["recipients"].array ?? []).compactMap { $0["id"].string }) == [
        family.child.id, family.deactivatedChild.id,
      ])
    #expect(shared["can_edit"] == true)

    // The invitation is still pending, and nobody can accept it while the child is deactivated.
    let invitations = try await parent.get("/invitations?user_id=\(family.deactivatedChild.id)")
    #expect(ids(invitations) == [family.pendingInvitation.id])
    let invitation = try await parent.get("/invitations/\(family.pendingInvitation.id)")
    #expect(invitation["list"]["id"].string == family.parentList.id)
    #expect(invitation["can_accept"] == false)
    #expect(try await parent.get("/lists/\(family.parentList.id)")["recipients"].array?.count == 1)

    // A parent sees the gifts given to their child, without the giver's private fields.
    let gifts = try await parent.get("/gifts?recipient_id=\(family.deactivatedChild.id)")
    #expect(ids(gifts) == [family.givenGift.id])
    let gift = try await parent.get("/gifts/\(family.givenGift.id)")
    #expect(gift["state"] == "given")
    #expect(gift["title"].string == family.givenGift.item.title)
    #expect(gift["giver"]["id"].string == family.relative.id)
    #expect(gift["from_label"] == "The cousins")
    #expect(gift["note"].isNull)
    // The gift is for the family's own group occasion, on every day of the year, whatever else is on the server.
    #expect(gift["occasion"]["id"].string == family.groupOccasion.id)
    #expect(gift["occasion_name"].string == family.groupOccasion.name)
  }

  private func readsBackAsTheChild(_ family: StandardFamily) async throws {
    let child = try family.child.signedIn()
    // The child is a recipient of the shared list, so they see it, and their sibling as a summary on it.
    let lists = try await child.get("/lists?recipient_id=\(family.child.id)")
    #expect(ids(lists).contains(family.sharedList.id))
    #expect(try await child.get("/lists/\(family.sharedList.id)")["can_edit"] == true)
    #expect(try await child.get("/lists/\(family.sharedList.id)/items")["data"].array?.count == 1)
    // The sibling's own lists show only through the sibling, who is deactivated.
    #expect(try await child.status(of: "/lists/\(family.primaryList.id)") == 404)
    #expect(try await child.status(of: "/gifts/\(family.givenGift.id)") == 404)
    // Both shared occasions apply to the child.
    let occasions = Set(try await child.all("/occasions?kind=shared").compactMap { $0["id"].string })
    #expect(occasions.isSuperset(of: [family.groupOccasion.id, family.everyoneOccasion.id]))
  }

  private func readsBackAsTheRelative(_ family: StandardFamily) async throws {
    let relative = try family.relative.signedIn()
    // The relative is directly in the outer group, and not in the inner one.
    #expect(try await relative.status(of: "/groups/\(family.family.id)") == 200)
    #expect(try await relative.status(of: "/groups/\(family.household.id)") == 404)
    // The parent is in the outer group through the inner one.
    let outer = try await family.parent.signedIn().get("/groups/\(family.family.id)")
    #expect(outer["through"]["id"].string == family.household.id)

    // The gift is in the relative's Given, with the fields that only its giver sees.
    let given = try await relative.get("/gifts?giver_id=me&state=given")
    #expect(ids(given) == [family.givenGift.id])
    let gift = try await relative.get("/gifts/\(family.givenGift.id)")
    #expect(gift["is_bought"] == false)
    #expect(gift["occasion"]["id"].string == family.groupOccasion.id)
    #expect(try await relative.get("/gifts?giver_id=me&state=open")["data"].array?.isEmpty == true)
  }

  private func readsBackAsTheOutsider(_ family: StandardFamily) async throws {
    let outsider = try family.outsider.signedIn()
    #expect(try await outsider.get("/groups")["data"].array?.isEmpty == true)
    #expect(ids(try await outsider.get("/lists")).count == 1)
    // The occasion for everyone reaches a user in no group. The group's occasion doesn't.
    #expect(try await outsider.status(of: "/occasions/\(family.everyoneOccasion.id)") == 200)
    #expect(try await outsider.status(of: "/occasions/\(family.groupOccasion.id)") == 404)
  }

  @Test("Two families on one server have their own names, and don't see each other")
  func twoFamilies() async throws {
    let server = try await TestServer.shared()
    let first = try await FixtureBuilder(server: server).standardFamily()
    let second = try await FixtureBuilder(server: server).standardFamily()

    #expect(first.parent.name != second.parent.name)
    #expect(first.blockedStore.store != second.blockedStore.store)
    #expect(first.admin.id == second.admin.id)
    #expect(try await first.parent.signedIn().status(of: "/users/\(second.parent.id)") == 404)
    #expect(try await first.parent.signedIn().status(of: "/lists/\(second.parentList.id)") == 404)

    // An occasion marked everyone is for the whole instance, so each family sees the other's. Each family's gift
    // is still for its own group occasion.
    #expect(try await second.parent.signedIn().status(of: "/occasions/\(first.everyoneOccasion.id)") == 200)
    for family in [first, second] {
      let gift = try await family.relative.signedIn().get("/gifts/\(family.givenGift.id)")
      #expect(gift["occasion"]["id"].string == family.groupOccasion.id)
    }
  }

  @Test("A test that needs less seeds less, and reveal goes through the server's test hook")
  func smallBuilderCalls() async throws {
    let builder = try await FixtureBuilder(server: try await TestServer.shared())
    let recipient = try await builder.person("Alex")
    let giver = try await builder.person("Blake")
    _ = try await builder.group("Friends", users: [recipient, giver])
    let item = try await builder.item("Scarf", on: try await builder.primaryList(of: recipient), as: recipient)
    let gift = try await builder.claim(item, as: giver, note: "Wrap it")

    // An open gift shows only to its giver.
    #expect(try await giver.signedIn().get("/gifts/\(gift.id)")["state"] == "open")
    #expect(try await recipient.signedIn().status(of: "/gifts/\(gift.id)") == 404)

    #expect(try await builder.reveal(giftsFor: recipient) == 1)
    #expect(try await recipient.signedIn().get("/gifts/\(gift.id)")["state"] == "given")
  }
}
