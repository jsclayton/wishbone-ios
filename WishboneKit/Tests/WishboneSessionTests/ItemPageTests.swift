import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// An item's page, from the copy: its images with the primary first, its price, its list and recipients, how many
/// are still wanted or wanted, its store links in the viewer's order, "Added by", Copy link, the "not found" page,
/// and a move. See `docs/screens/item.md`.
@Suite("An item's page", .timeLimit(.minutes(1)))
@MainActor
struct ItemPageTests {
  /// A new device, signed in as the person. Its first sync has ended.
  private func signedIn(as person: Fixture.Person, on instance: Instance) async throws -> SessionModel {
    let instance = try await Instance(server: instance.server)
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: person))
    return try #require(device.session)
  }

  @Test("The item has its images with the primary first, its price or range, its list and its recipients")
  func content() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.list("Wishes", of: family.child)
    let images = [
      try await builder.image(as: family.child), try await builder.image(as: family.child),
      try await builder.image(as: family.child),
    ]
    let item = try await builder.item("Lamp", on: list, as: family.child, imageIDs: images)
    // The last image becomes the primary one.
    try await family.child.signedIn().send(
      "PATCH", "/items/\(item.id)",
      json: [
        "primary_image_id": .string(images[2]), "top_price_minor": 4500,
        "price_minor": 2000, "currency": "USD",
      ]
    ).expecting(200)
    let session = try await signedIn(as: family.relative, on: instance)

    let page = try #require(session.itemPage(id: item.id))
    #expect(page.item.title == "Lamp")
    #expect(page.images.map(\.id) == [images[2], images[0], images[1]])
    #expect(page.item.priceMinor == 2000)
    #expect(page.item.topPriceMinor == 4500)
    #expect(page.item.currency == "USD")
    #expect(page.list.id == list.id)
    #expect(page.list.name == list.name)
    #expect(page.recipients.map(\.user.id) == [family.child.id])
    #expect(page.recipients.allSatisfy { $0.isLinked })
  }

  @Test("The store links come lowest price first for a giver, and in the order added for a user who can edit")
  func storeLinkOrder() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.list("Wishes", of: family.child)
    let item = try await builder.item(
      "Lamp", on: list, as: family.child,
      storeLinks: [
        (url: "https://dear.example/lamp", priceMinor: 4999), (url: "https://none.example/lamp", priceMinor: nil),
        (url: "https://cheap.example/lamp", priceMinor: 1999),
      ])

    let giver = try await signedIn(as: family.relative, on: instance)
    let asGiver = try #require(giver.itemPage(id: item.id))
    #expect(
      asGiver.storeLinks.map(\.url) == [
        "https://cheap.example/lamp", "https://dear.example/lamp", "https://none.example/lamp",
      ])

    let recipient = try await signedIn(as: family.child, on: instance)
    let asRecipient = try #require(recipient.itemPage(id: item.id))
    #expect(
      asRecipient.storeLinks.map(\.url) == [
        "https://dear.example/lamp", "https://none.example/lamp", "https://cheap.example/lamp",
      ])
    #expect(asRecipient.storeLinks.first?.priceMinor == 4999)
    #expect(asRecipient.storeLinks.first?.store.isEmpty == false)
  }

  @Test("\"Added by\" shows, and is hidden when that user is the only recipient")
  func addedBy() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.list("Wishes", of: family.child)
    let byParent = try await builder.item("Scarf", on: list, as: family.parent)
    let byChild = try await builder.item("Hat", on: list, as: family.child)
    let session = try await signedIn(as: family.relative, on: instance)
    // The shared list has two recipients, and the child added its item.
    let bunkBed = try #require(session.items(onList: family.sharedList.id).first?.id)

    #expect(try #require(session.itemPage(id: byParent.id)).addedBy?.id == family.parent.id)
    #expect(try #require(session.itemPage(id: byParent.id)).addedBy?.name == family.parent.name)
    #expect(try #require(session.itemPage(id: byChild.id)).addedBy == nil)
    #expect(try #require(session.itemPage(id: bunkBed)).addedBy?.id == family.child.id)
  }

  @Test("\"Added by\" is hidden when that user was deleted")
  func addedByDeleted() {
    // The pinned server has no way to delete a user, so this holds the rule on its own: a deleted user is an item
    // with no `added_by`.
    #expect(ItemPage.addedByID(nil, recipientIDs: ["1"]) == nil)
    #expect(ItemPage.addedByID("1", recipientIDs: ["1"]) == nil)
    #expect(ItemPage.addedByID("2", recipientIDs: ["1"]) == "2")
    #expect(ItemPage.addedByID("1", recipientIDs: ["1", "2"]) == "1")
  }

  @Test("A giver gets still wanted, a recipient does not, and an unlimited item gives \"Always wanted\"")
  func howMany() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.list("Wishes", of: family.child)
    let scarf = try await builder.item("Scarf", on: list, as: family.child, quantity: 3)
    let socks = try await builder.item("Socks", on: list, as: family.child, isUnlimited: true)
    _ = try await builder.claim(scarf, as: family.relative, for: family.groupOccasion)

    let giver = try await signedIn(as: family.relative, on: instance)
    #expect(try #require(giver.itemPage(id: scarf.id)).stillWanted == .count(2, of: 3))
    #expect(try #require(giver.itemPage(id: socks.id)).stillWanted == .always)
    #expect(try #require(giver.itemPage(id: scarf.id)).wanted == nil)

    let recipient = try await signedIn(as: family.child, on: instance)
    #expect(try #require(recipient.itemPage(id: scarf.id)).stillWanted == nil)
    #expect(try #require(recipient.itemPage(id: scarf.id)).wanted == .count(3))
    #expect(try #require(recipient.itemPage(id: socks.id)).stillWanted == nil)
    #expect(try #require(recipient.itemPage(id: socks.id)).wanted == .always)

    // A parent who is not a recipient gets both.
    let parent = try await signedIn(as: family.parent, on: instance)
    let asParent = try #require(parent.itemPage(id: scarf.id))
    #expect(asParent.stillWanted == .count(2, of: 3))
    #expect(asParent.wanted == .count(3))
  }

  @Test("Copy link gives the first store link in this viewer's order and nothing else, and is absent with none")
  func copyLink() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.list("Wishes", of: family.child)
    let lamp = try await builder.item(
      "Lamp", on: list, as: family.child,
      storeLinks: [
        (url: "https://dear.example/lamp", priceMinor: 4999), (url: "https://cheap.example/lamp", priceMinor: 1999),
      ])
    let mug = try await builder.item("Mug", on: list, as: family.child)

    let giver = try await signedIn(as: family.relative, on: instance)
    #expect(try #require(giver.itemPage(id: lamp.id)).copyLink == URL(string: "https://cheap.example/lamp"))
    #expect(try #require(giver.itemPage(id: mug.id)).copyLink == nil)

    let recipient = try await signedIn(as: family.child, on: instance)
    #expect(try #require(recipient.itemPage(id: lamp.id)).copyLink == URL(string: "https://dear.example/lamp"))
  }

  @Test("A deleted item, and one that a giver can no longer see, give the same \"not found\" page")
  func notFound() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.list("Wishes", of: family.child)
    let deleted = try await builder.item("Lamp", on: list, as: family.child)
    let claimed = try await builder.item("Book", on: list, as: family.child)
    let aunt = try await builder.person("Avery")
    _ = try await builder.group("Aunts", users: [aunt, family.child])
    // This test syncs again, so it keeps the device's instance, whose network the device goes through.
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: family.relative))
    let session = try #require(device.session)
    #expect(session.itemPage(id: deleted.id) != nil)
    #expect(session.itemPage(id: claimed.id) != nil)

    _ = try await family.child.signedIn().send("DELETE", "/items/\(deleted.id)").expecting(204)
    // Another giver claims the book in full, so the relative no longer sees it.
    _ = try await builder.claim(claimed, as: aunt)
    await session.syncNow()
    await until { session.itemPage(id: deleted.id) == nil && session.itemPage(id: claimed.id) == nil }
    #expect(session.itemPage(id: "0") == nil)
  }

  @Test("After the item moves on the server and the app syncs, the page shows the new list's name")
  func move() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let first = try await builder.list("Wishes", of: family.child)
    let second = try await builder.list("Someday", of: family.child)
    let item = try await builder.item("Lamp", on: first, as: family.child)
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: family.relative))
    let session = try #require(device.session)
    #expect(try #require(session.itemPage(id: item.id)).list.name == first.name)

    try await family.child.signedIn().send("PATCH", "/items/\(item.id)", json: ["list_id": .string(second.id)])
      .expecting(200)
    await session.syncNow()
    await until { session.itemPage(id: item.id)?.list.id == second.id }
    #expect(try #require(session.itemPage(id: item.id)).list.name == second.name)
  }
}
