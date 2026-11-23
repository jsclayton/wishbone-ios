import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// A gift's page, for an open gift, from the copy: the item as it is now, who the gift is for, its occasion and its
/// reveal date, each change of a changed item, an item that was removed, what the giver can't see, a gift that went
/// away, and the item page's lines that open it. See `docs/screens/gift.md`.
@Suite("A gift's page", .timeLimit(.minutes(2)))
@MainActor
struct GiftPageTests {
  /// A device of the instance, signed in as the person. Its first sync has ended, and the session has published
  /// what the instance names for the person.
  private func signedIn(as person: Fixture.Person, on instance: Instance) async throws -> SessionModel {
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    try await untilInStep(session, as: person)
    return session
  }

  /// A shared occasion of the family, the days from today, so that every gift for it is far from its reveal.
  private func occasion(
    _ name: String, inDays days: Int, of family: StandardFamily, builder: FixtureBuilder
  ) async throws -> Fixture.Occasion {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let date = try #require(calendar.date(byAdding: .day, value: days, to: .now))
    let month = calendar.component(.month, from: date)
    // An annual occasion on Feb 29 would skip years.
    let day = min(calendar.component(.day, from: date), month == 2 ? 28 : 31)
    return try await builder.sharedOccasion(name, month: month, day: day, groups: [family.family])
  }

  // MARK: - 1. An open gift

  @Test("An open gift has the item's fields as they are now, who it is for, its occasion and its reveal date")
  func content() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let spring = try await occasion("Spring", inDays: 60, of: family, builder: builder)
    let list = try await builder.list("Wishes", of: family.child)
    let image = try await builder.image(as: family.child)
    let kite = try await builder.item("Kite", on: list, as: family.child, imageIDs: [image])
    try await family.child.signedIn().send(
      "PATCH", "/items/\(kite.id)", json: ["price_minor": 2000, "top_price_minor": 3500, "currency": "USD"]
    ).expecting(200)
    let gift = try await builder.claim(
      kite, as: family.relative, for: spring, fromLabel: "Emma", note: "Blue string", isBought: true)
    let session = try await signedIn(as: family.relative, on: instance)

    // The recipient changes the title after the claim. The page has the title as it is now.
    try await family.child.signedIn().send("PATCH", "/items/\(kite.id)", json: ["title": "Red kite"]).expecting(200)
    await session.syncNow()
    await until { session.giftPage(id: gift.id)?.gift.title == "Red kite" }

    let page = try #require(session.giftPage(id: gift.id))
    let onServer = try await family.relative.signedIn().get("/gifts/\(gift.id)")
    #expect(page.gift.title == "Red kite")
    #expect(page.gift.image?.id == image)
    #expect(page.gift.priceMinor == 2000)
    #expect(page.gift.topPriceMinor == 3500)
    #expect(page.gift.currency == "USD")
    #expect(page.recipients?.map(\.name) == [family.child.name])
    #expect(page.occasion == .named(spring.name))
    #expect(page.gift.occasionDate == onServer["occasion_date"].string)
    #expect(page.gift.revealAt > .now)
    #expect(page.gift.isBought == .shown(true))
    #expect(page.gift.fromLabel == "Emma")
    #expect(page.gift.note == .shown("Blue string"))
    #expect(page.gift.quantity == 1)
    #expect(page.gift.listName == list.name)

    // The title opens the item's page, and the list's name the list's page.
    #expect(page.linksItem)
    #expect(page.linksList)
    #expect(session.itemPage(id: page.gift.itemID) != nil)
    #expect(session.listPage(id: page.gift.listID) != nil)

    // The title changed, so the page says so, old to new.
    #expect(page.flags == [.changed])
    #expect(page.changes == [.title(old: "Kite", new: "Red kite")])
  }

  // MARK: - 2. A changed item

  @Test(
    """
    A changed flag lists each change: a title, a price that went to none, the primary image, a store link's price, \
    and a store link removed
    """
  )
  func changes() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let spring = try await occasion("Spring", inDays: 60, of: family, builder: builder)
    let list = try await builder.list("Wishes", of: family.child)
    let images = [try await builder.image(as: family.child), try await builder.image(as: family.child)]
    let kite = try await builder.item(
      "Kite", on: list, as: family.child,
      storeLinks: [
        (url: "https://dear.example/kite", priceMinor: 2499), (url: "https://cheap.example/kite", priceMinor: 999),
      ],
      imageIDs: images)
    let child = try family.child.signedIn()
    try await child.send("PATCH", "/items/\(kite.id)", json: ["price_minor": 2000, "currency": "USD"]).expecting(200)
    let gift = try await builder.claim(kite, as: family.relative, for: spring)
    let session = try await signedIn(as: family.relative, on: instance)
    #expect(try #require(session.giftPage(id: gift.id)).changes.isEmpty)

    // The recipient changes each field in turn.
    let links = try await child.all("/items/\(kite.id)/store-links")
    let dear = try #require(links.first { $0["url"].string == "https://dear.example/kite" }?["id"].string)
    let cheap = try #require(links.first { $0["url"].string == "https://cheap.example/kite" }?["id"].string)
    try await child.send("PATCH", "/items/\(kite.id)", json: ["title": "Red kite"]).expecting(200)
    try await child.send("PATCH", "/items/\(kite.id)", json: ["price_minor": nil]).expecting(200)
    try await child.send("PATCH", "/items/\(kite.id)", json: ["primary_image_id": .string(images[1])]).expecting(200)
    try await child.send("PATCH", "/items/\(kite.id)/store-links/\(dear)", json: ["price_minor": 1999])
      .expecting(200)
    try await child.send("DELETE", "/items/\(kite.id)/store-links/\(cheap)").expecting(204)
    await session.syncNow()
    await until { session.giftPage(id: gift.id)?.changes.count == 5 }

    let page = try #require(session.giftPage(id: gift.id))
    #expect(page.flags == [.changed])
    #expect(
      page.changes == [
        .title(old: "Kite", new: "Red kite"),
        .price(old: .init(priceMinor: 2000, currency: "USD"), new: nil),
        .photo,
        .storeLinkPrice(
          store: "dear.example", old: .init(priceMinor: 2499, currency: "USD"),
          new: .init(priceMinor: 1999, currency: "USD")),
        .storeLinkRemoved(store: "cheap.example"),
      ])
    #expect(page.gift.priceMinor == nil)
    #expect(page.gift.image?.id == images[1])
  }

  // MARK: - 3. A removed item

  @Test("A gift whose item was removed shows the item as it was, with no link")
  func removed() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let spring = try await occasion("Spring", inDays: 60, of: family, builder: builder)
    let list = try await builder.list("Wishes", of: family.child)
    let kite = try await builder.item("Kite", on: list, as: family.child)
    try await family.child.signedIn().send(
      "PATCH", "/items/\(kite.id)", json: ["price_minor": 1500, "currency": "USD"]
    ).expecting(200)
    let gift = try await builder.claim(kite, as: family.relative, for: spring)
    let session = try await signedIn(as: family.relative, on: instance)
    #expect(try #require(session.giftPage(id: gift.id)).linksItem)

    try await family.child.signedIn().send("DELETE", "/items/\(kite.id)").expecting(204)
    await session.syncNow()
    await until { session.giftPage(id: gift.id)?.flags.contains(.removed) == true }

    let page = try #require(session.giftPage(id: gift.id))
    #expect(page.gift.title == "Kite")
    #expect(page.gift.priceMinor == 1500)
    #expect(page.recipients?.map(\.name) == [family.child.name])
    #expect(!page.linksItem)
    #expect(session.itemPage(id: kite.id) == nil)
  }

  // MARK: - 4. What the giver can't see

  @Test("A hidden occasion gives only the reveal date, and a hidden list gives no \"For\" line and no link")
  func hidden() async throws {
    let instance = try await Instance(server: try await TestServer.start())
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.primaryList(of: family.child)
    let kite = try await builder.claim(
      try await builder.item("Kite", on: list, as: family.child), as: family.relative, for: family.groupOccasion)
    let session = try await signedIn(as: family.relative, on: instance)
    #expect(try #require(session.giftPage(id: kite.id)).linksList)

    // The occasion is hidden: the server sends no occasion, and no name.
    try await answer(kite, as: family.relative, to: session, on: instance) { body in
      body["occasion"] = .null
      body["occasion_name"] = .null
    }
    let revealAt = try #require(session.gift(id: kite.id)?.revealAt)
    var page = try #require(session.giftPage(id: kite.id))
    #expect(page.occasion == .hiddenUntil(revealAt))
    #expect(page.recipients?.map(\.name) == [family.child.name])
    #expect(page.linksList)

    // The list is hidden too: the server sends no `recipients`.
    try await answer(kite, as: family.relative, to: session, on: instance) { body in
      body["occasion"] = .null
      body["occasion_name"] = .null
      body.removeValue(forKey: "recipients")
    }
    page = try #require(session.giftPage(id: kite.id))
    #expect(page.recipients == nil)
    #expect(!page.linksList)
    #expect(page.occasion == .hiddenUntil(revealAt))
  }

  // MARK: - 5. Gone

  @Test("A gift that was unclaimed from another device gives the \"not found\" page after a sync")
  func gone() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.list("Wishes", of: family.child)
    let kite = try await builder.claim(
      try await builder.item("Kite", on: list, as: family.child), as: family.relative, for: family.groupOccasion)
    let session = try await signedIn(as: family.relative, on: instance)
    #expect(session.giftPage(id: kite.id) != nil)

    // The recipient never sees the open gift: for them it is "not found".
    // A device of their own, with its own keychain.
    let recipient = try await signedIn(as: family.child, on: try await Instance(server: instance.server))
    #expect(recipient.giftPage(id: kite.id) == nil)

    // Another device of the giver unclaims it.
    try await family.relative.signedIn().send("DELETE", "/gifts/\(kite.id)").expecting(204)
    await session.syncNow()
    try await untilInStep(session, as: family.relative)
    #expect(session.gift(id: kite.id) == nil)
    #expect(session.giftPage(id: kite.id) == nil)
  }

  // MARK: - 6. The item's lines

  @Test("An item's page has one line for each of the giver's open gifts on it, and each opens its gift")
  func itemLines() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let spring = try await occasion("Spring", inDays: 60, of: family, builder: builder)
    let summer = try await occasion("Summer", inDays: 120, of: family, builder: builder)
    let list = try await builder.list("Wishes", of: family.child)
    let lamp = try await builder.item("Lamp", on: list, as: family.child, quantity: 3)
    let forSpring = try await builder.claim(lamp, as: family.relative, for: spring)
    let forSummer = try await builder.claim(lamp, as: family.relative, for: summer)
    let session = try await signedIn(as: family.relative, on: instance)

    let item = try #require(session.itemPage(id: lamp.id))
    #expect(item.claims.map(\.id) == [forSpring.id, forSummer.id])
    #expect(item.claims.map(\.occasion) == [.named(spring.name), .named(summer.name)])
    for line in item.claims {
      let page = try #require(session.giftPage(id: line.id))
      #expect(page.gift.itemID == lamp.id)
      #expect(page.occasion == line.occasion)
    }
  }
}
