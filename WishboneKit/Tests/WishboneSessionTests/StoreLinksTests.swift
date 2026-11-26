import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// An item's store links, at the session model's seam, against the real server and store pages that it reads: Add
/// link and Refresh prices, which wait for the server, and a price edit and Remove in the Edit item sheet, which are
/// unsent changes. See "Edit item", States and Actions in `docs/screens/item.md`, and in `docs/spec.md`: "Other writes
/// that wait for the server" and "Unsent changes".
@Suite("An item's store links", .timeLimit(.minutes(2)))
@MainActor
final class StoreLinksTests {
  typealias Route = NetworkConditioner.Route

  static let addLink = Route("POST", "/items/{id}/store-links")
  static let updateLink = Route("PATCH", "/items/{id}/store-links/{store_link_id}")
  static let deleteLink = Route("DELETE", "/items/{id}/store-links/{store_link_id}")
  static let refresh = Route("POST", "/items/{id}/refresh-prices")
  static let updateItem = Route("PATCH", "/items/{id}")
  static let create = Route("POST", "/lists/{id}/items")

  let instance: Instance

  /// The one window of the app, as it comes to the foreground.
  let window = UUID()

  init() async throws {
    instance = try await Instance()
  }

  /// A device signed in as the person, through this test's conditioner, with the copy in step with the instance.
  private func signedIn(
    as person: Fixture.Person, diagnostics: any DiagnosticsReporter = .none
  ) async throws -> SessionModel {
    let device = instance.device(diagnostics: diagnostics)
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    try await untilInStep(session, as: person)
    return session
  }

  /// The item as the person reads it from the server.
  private func onServer(_ id: String, as person: Fixture.Person) async throws -> JSON {
    try await person.signedIn().get("/items/\(id)")
  }

  /// The item's store links as the person reads them from the server, in the order added.
  private func linksOnServer(_ id: String, as person: Fixture.Person) async throws -> [JSON] {
    try await onServer(id, as: person)["store_links"].array ?? []
  }

  /// The requests on the route that the conditioner saw, from the index on.
  private func seen(_ route: Route, from index: Int = 0) -> [NetworkConditioner.SeenRequest] {
    instance.conditioner.requests[index...].filter { $0.isOn(route) }
  }

  /// The names of the fields of a request's JSON body.
  private func fields(of request: NetworkConditioner.SeenRequest) throws -> Set<String> {
    guard case .object(let fields) = try JSON(parsing: request.body) else { return [] }
    return Set(fields.keys)
  }

  /// The draft of the item as the copy has it, as the sheet opens it.
  private func draft(of id: String, in session: SessionModel, sourceLocation: SourceLocation = #_sourceLocation)
    async throws -> ItemEditDraft
  {
    try #require(await session.editDraft(ofItem: id), sourceLocation: sourceLocation)
  }

  /// A person with one item on their primary list, with the store links given, each an address and a price in
  /// cents. The server reads no page for them.
  private func person(
    withItem title: String, links: [(url: String, priceMinor: Int?)] = []
  ) async throws -> (Fixture.Person, Fixture.Item) {
    let builder = instance.builder
    let person = try await builder.person("Robin")
    let list = try await builder.primaryList(of: person)
    let item = try await builder.item(title, on: list, as: person, storeLinks: links)
    return (person, item)
  }

  /// The two shops of the standard item of these tests, each with a price.
  private var twoShops: [(url: String, priceMinor: Int?)] {
    let tag = instance.builder.tag
    return [("https://one-\(tag).example/kite", 2500), ("https://two-\(tag).example/kite", 3000)]
  }

  /// A link that Add link added.
  private func added(_ outcome: StoreLinkOutcome, sourceLocation: SourceLocation = #_sourceLocation) throws
    -> StoreLinkRow
  {
    guard case .added(let link) = outcome else {
      Issue.record("Add link ended with \(outcome)", sourceLocation: sourceLocation)
      throw CancellationError()
    }
    return link
  }

  // MARK: - 1. Add link

  @Test(
    """
    Add link gives a store link with its store and its price, at once and with nothing to send, and an item with no \
    price takes that price
    """
  )
  func addLink() async throws {
    let page = try await StorePage(title: "Kite \(instance.builder.tag)", priceMinor: 2499)
    let (person, item) = try await person(withItem: "Kite")
    let session = try await signedIn(as: person)
    #expect(session.item(id: item.id)?.priceMinor == nil)
    let opened = try await draft(of: item.id, in: session)
    #expect(opened.storeLinks.isEmpty)
    #expect(opened.canAddStoreLink)

    let link = try added(await session.addStoreLink("  \(page.url.absoluteString)  ", toItem: item.id))

    // The copy has it as the server gave it, before any sync, with the page's price, read just now.
    #expect(link.store == "127.0.0.1")
    #expect(link.url.contains(page.url.path()))
    #expect(link.priceMinor == 2499)
    #expect(link.currency == "USD")
    #expect(link.capturedAt != nil)
    #expect(link.canEdit && link.canDelete)
    #expect(session.storeLinks(ofItem: item.id).map(\.id) == [link.id])
    #expect(session.itemPage(id: item.id)?.storeLinks.map(\.id) == [link.id])
    // An item with no price takes the link's.
    #expect(session.item(id: item.id)?.priceMinor == 2499)
    #expect(session.item(id: item.id)?.currency == "USD")
    // It waited for the server, so nothing waits to be sent.
    #expect(session.unsentChangeCount == 0)

    let requests = seen(Self.addLink)
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(try fields(of: request) == ["url"])
    #expect(try JSON(parsing: request.body)["url"].string == page.url.absoluteString)
    #expect(request.headers["idempotency-key"] != nil)
    #expect(page.reads == 1)
    let saved = try await onServer(item.id, as: person)
    #expect(saved["price_minor"].number == 2499)
    #expect(saved["store_links"][0]["id"].string == link.id)
    #expect(saved["store_links"][0]["price_minor"].number == 2499)

    // The sheet puts the link in the draft it opened with too: Add link is no change for Save to send.
    var draft = opened
    var openedWithLink = opened
    openedWithLink.added(link)
    draft.added(link)
    #expect(draft.storeLinks.map(\.id) == [link.id])
    await session.editItem(item.id, from: openedWithLink, to: draft)
    #expect(session.unsentChangeCount == 0)
    #expect(seen(Self.updateLink).isEmpty && seen(Self.updateItem).isEmpty)
  }

  @Test("Add link keeps the price of an item that has one, and goes after the links it has")
  func addLinkKeepsThePrice() async throws {
    let page = try await StorePage(title: "Lamp \(instance.builder.tag)", priceMinor: 4200)
    let builder = instance.builder
    let person = try await builder.person("Robin")
    let list = try await builder.primaryList(of: person)
    let item = try await builder.item("Lamp", on: list, as: person, storeLinks: [twoShops[0]])
    try await person.signedIn().send("PATCH", "/items/\(item.id)", json: ["price_minor": .number(1000)])
      .expecting(200)
    let session = try await signedIn(as: person)
    #expect(session.item(id: item.id)?.priceMinor == 1000)

    let link = try added(await session.addStoreLink(page.url.absoluteString, toItem: item.id))

    #expect(session.item(id: item.id)?.priceMinor == 1000)
    #expect(session.storeLinks(ofItem: item.id).count == 2)
    #expect(session.storeLinks(ofItem: item.id).last?.id == link.id)
    #expect(try await onServer(item.id, as: person)["price_minor"].number == 1000)
  }

  // MARK: - 2. With no connection

  @Test("With the network dropped, Add link and Refresh prices say Can't reach, change nothing, and queue nothing")
  func offline() async throws {
    let page = try await StorePage(title: "Drum \(instance.builder.tag)", priceMinor: 1500)
    let (person, item) = try await person(withItem: "Drum", links: [twoShops[0]])
    let session = try await signedIn(as: person)
    let before = session.storeLinks(ofItem: item.id)
    let price = session.item(id: item.id)?.priceMinor
    #expect(session.offersRefreshPrices(onItem: item.id))

    instance.conditioner.dropEverything()
    #expect(await session.addStoreLink(page.url.absoluteString, toItem: item.id) == .unreachable)
    #expect(await session.refreshPrices(ofItem: item.id) == .unreachable)

    #expect(session.storeLinks(ofItem: item.id) == before)
    #expect(session.item(id: item.id)?.priceMinor == price)
    #expect(session.unsentChangeCount == 0)

    // When the instance answers again, a sync sends nothing, and the server never read the page.
    instance.conditioner.passEverything()
    let sent = instance.conditioner.requests.count
    await session.syncNow()
    #expect(seen(Self.addLink, from: sent).isEmpty)
    #expect(seen(Self.refresh, from: sent).isEmpty)
    #expect(page.reads == 0)
    #expect(try await linksOnServer(item.id, as: person).count == 1)
    try await untilInStep(session, as: person)
    #expect(session.storeLinks(ofItem: item.id).map(\.id) == before.map(\.id))
  }

  // MARK: - 3. What the server refuses

  @Test("A link from a blocked store adds nothing, names the store, and is not captured")
  func blockedStore() async throws {
    let blocked = try await instance.builder.blockedStore("shop")
    let (person, item) = try await person(withItem: "Kite")
    let diagnostics = RecordingDiagnostics()
    let session = try await signedIn(as: person, diagnostics: diagnostics)

    let outcome = await session.addStoreLink("https://www.\(blocked.store)/products/kite", toItem: item.id)

    #expect(outcome == .blocked(store: blocked.store))
    #expect(session.storeLinks(ofItem: item.id).isEmpty)
    #expect(session.unsentChangeCount == 0)
    #expect(try await linksOnServer(item.id, as: person).isEmpty)
    #expect(diagnostics.faults.isEmpty, "\(diagnostics.faults)")
  }

  @Test("An eleventh link adds nothing, with too_many_store_links, which is captured by its route and code")
  func eleventhLink() async throws {
    let page = try await StorePage(title: "Bike \(instance.builder.tag)", priceMinor: 9900)
    let tag = instance.builder.tag
    let ten = (0..<10).map { (url: "https://shop\($0)-\(tag).example/bike", priceMinor: Int?.none) }
    let (person, item) = try await person(withItem: "Bike", links: ten)
    let diagnostics = RecordingDiagnostics()
    let session = try await signedIn(as: person, diagnostics: diagnostics)
    // The sheet can't use Add link at 10, and says why.
    #expect(try await draft(of: item.id, in: session).canAddStoreLink == false)

    let outcome = await session.addStoreLink(page.url.absoluteString, toItem: item.id)

    guard case .refused(let refusal) = outcome else {
      Issue.record("Add link ended with \(outcome)")
      return
    }
    #expect(refusal.code == .tooManyStoreLinks)
    #expect(refusal.route == .addStoreLink)
    #expect(session.storeLinks(ofItem: item.id).count == 10)
    #expect(session.unsentChangeCount == 0)
    #expect(page.reads == 0)
    #expect(try await linksOnServer(item.id, as: person).count == 10)
    #expect(diagnostics.faults == [.refusedWrite(.addStoreLink, code: "too_many_store_links")])
  }

  @Test(
    """
    Over the hourly limit, Refresh prices and Add link each change nothing, with rate_limited, and neither is \
    captured
    """
  )
  func overTheHourlyLimit() async throws {
    let page = try await StorePage(title: "Easel \(instance.builder.tag)", priceMinor: 5000)
    // Ten links to the store's page, which a refresh reads each time: three refreshes read 30 pages, the limit.
    let ten = (0..<10).map { (url: "\(page.url.absoluteString)?n=\($0)", priceMinor: Int?.some(100)) }
    let builder = instance.builder
    let person = try await builder.person("Robin")
    let list = try await builder.primaryList(of: person)
    let full = try await builder.item("Easel", on: list, as: person, storeLinks: ten)
    let other = try await builder.item("Paints", on: list, as: person)
    for _ in 0..<3 {
      try await person.signedIn().send("POST", "/items/\(full.id)/refresh-prices").expecting(200)
    }
    #expect(page.reads == 30)
    let diagnostics = RecordingDiagnostics()
    let session = try await signedIn(as: person, diagnostics: diagnostics)
    let before = session.storeLinks(ofItem: full.id)

    let refreshed = await session.refreshPrices(ofItem: full.id)
    let addedLink = await session.addStoreLink("\(page.url.absoluteString)?n=new", toItem: other.id)

    guard case .refused(let refreshRefusal) = refreshed, case .refused(let addRefusal) = addedLink else {
      Issue.record("Refresh prices ended with \(refreshed), and Add link with \(addedLink)")
      return
    }
    #expect(refreshRefusal.code == .rateLimited && refreshRefusal.route == .refreshPrices)
    #expect(addRefusal.code == .rateLimited && addRefusal.route == .addStoreLink)
    #expect(session.storeLinks(ofItem: full.id) == before)
    #expect(session.storeLinks(ofItem: other.id).isEmpty)
    #expect(session.unsentChangeCount == 0)
    #expect(try await linksOnServer(other.id, as: person).isEmpty)
    #expect(diagnostics.faults.isEmpty, "\(diagnostics.faults)")
  }

  // MARK: - 4. A price edit

  @Test(
    """
    A price edit and a cleared price are unsent changes: they show at once, and reach the server as a merge patch of \
    the price alone
    """
  )
  func priceEdit() async throws {
    let (person, item) = try await person(withItem: "Kite", links: twoShops)
    let session = try await signedIn(as: person)
    let links = session.storeLinks(ofItem: item.id)
    #expect(links.map(\.priceMinor) == [2500, 3000])

    // Held at the request, so what shows at once can't be the server's answer.
    let hold = instance.conditioner.hold(Self.updateLink, at: .request)
    let opened = try await draft(of: item.id, in: session)
    #expect(opened.storeLinks.map(\.id) == links.map(\.id))
    #expect(opened.storeLinks.allSatisfy { $0.canEdit && $0.canDelete })
    var draft = opened
    draft.storeLinks[0].priceMinor = 1999
    draft.storeLinks[1].priceMinor = nil
    let saved = Date.now
    await session.editItem(item.id, from: opened, to: draft)

    let shown = session.storeLinks(ofItem: item.id)
    #expect(shown.map(\.priceMinor) == [1999, nil])
    #expect(shown.map(\.currency) == ["USD", nil])
    // Each is read when the user saved it, the cleared one too, as the server does.
    #expect(shown.allSatisfy { ($0.capturedAt ?? .distantPast) >= saved.addingTimeInterval(-1) })
    #expect(session.itemPage(id: item.id)?.storeLinks.map(\.priceMinor) == [1999, nil])
    #expect(session.unsentChangeCount == 2)

    await hold.waitUntilHeld()
    hold.release()
    await until { session.unsentChangeCount == 0 }
    let patches = seen(Self.updateLink)
    #expect(patches.count == 2)
    #expect(patches.map(\.target) == links.map { "\(TestServer.apiPrefix)/items/\(item.id)/store-links/\($0.id)" })
    for patch in patches {
      #expect(try fields(of: patch) == ["price_minor"])
      #expect(patch.headers["idempotency-key"] != nil)
      #expect(patch.headers["if-match"] == nil)
    }
    #expect(try JSON(parsing: patches[0].body)["price_minor"].number == 1999)
    #expect(try JSON(parsing: patches[1].body)["price_minor"].isNull)
    // Only the links changed: the item's own fields were never sent.
    #expect(seen(Self.updateItem).isEmpty)

    let onServer = try await linksOnServer(item.id, as: person)
    #expect(onServer.map { $0["price_minor"].number } == [1999, nil])
    #expect(onServer[0]["captured_at"].string != nil)
    #expect(onServer[1]["currency"].isNull)
    try await untilInStep(session, as: person)
    #expect(session.storeLinks(ofItem: item.id).map(\.priceMinor) == [1999, nil])
  }

  @Test(
    """
    With the network dropped, a price edit and a Remove wait and show in the next sheet as the user left them, a \
    later Save never sends them again or brings the link back, and each reaches the server once, in order
    """
  )
  func offlineInOrder() async throws {
    let (person, item) = try await person(withItem: "Kite", links: twoShops)
    let session = try await signedIn(as: person)
    let links = session.storeLinks(ofItem: item.id)
    instance.conditioner.dropEverything()

    let first = try await draft(of: item.id, in: session)
    var edited = first
    edited.storeLinks[0].priceMinor = 2200
    await session.editItem(item.id, from: first, to: edited)
    await until { session.isInstanceUnreachable }

    // The next sheet opens with the price as the user left it.
    let second = try await draft(of: item.id, in: session)
    #expect(second.storeLinks.map(\.priceMinor) == [2200, 3000])
    var removed = second
    removed.removeStoreLink(links[1].id)
    await session.editItem(item.id, from: second, to: removed)
    #expect(session.storeLinks(ofItem: item.id).map(\.id) == [links[0].id])

    // A third sheet has the removed link no more, and a Save of the title alone touches no link.
    let third = try await draft(of: item.id, in: session)
    #expect(third.storeLinks.map(\.id) == [links[0].id])
    #expect(third.storeLinks.map(\.priceMinor) == [2200])
    var retitled = third
    retitled.title = "Box kite"
    await session.editItem(item.id, from: third, to: retitled)
    #expect(session.unsentChangeCount == 3)
    #expect(session.storeLinks(ofItem: item.id).map(\.id) == [links[0].id])
    #expect(session.storeLinks(ofItem: item.id).map(\.priceMinor) == [2200])

    instance.conditioner.passEverything()
    let sent = instance.conditioner.requests.count
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    let order = instance.conditioner.requests[sent...].compactMap { request in
      [Self.updateLink, Self.deleteLink, Self.updateItem].firstIndex { request.isOn($0) }
    }
    #expect(order == [0, 1, 2])
    let saved = try await onServer(item.id, as: person)
    #expect(saved["title"].string == "Box kite")
    #expect(saved["store_links"].array?.map { $0["id"].string } == [links[0].id])
    #expect(saved["store_links"][0]["price_minor"].number == 2200)
    #expect(session.lateRefusals.isEmpty)
    // Each landed once: a later sync sends nothing.
    await session.syncNow()
    #expect(seen(Self.updateLink, from: sent).count == 1)
    #expect(seen(Self.deleteLink, from: sent).count == 1)
  }

  @Test("A price changed elsewhere while the sheet is open is not sent back by a Save of another link")
  func staleDraft() async throws {
    let (person, item) = try await person(withItem: "Kite", links: twoShops)
    let session = try await signedIn(as: person)
    let links = session.storeLinks(ofItem: item.id)
    let opened = try await draft(of: item.id, in: session)

    // Meanwhile, another device sets the first link's price, and a sync brings it.
    try await person.signedIn().send(
      "PATCH", "/items/\(item.id)/store-links/\(links[0].id)", json: ["price_minor": .number(4000)]
    ).expecting(200)
    await session.syncNow()
    await until { session.storeLinks(ofItem: item.id).first?.priceMinor == 4000 }

    var draft = opened
    draft.storeLinks[1].priceMinor = 2800
    await session.editItem(item.id, from: opened, to: draft)
    await until { session.unsentChangeCount == 0 }

    #expect(seen(Self.updateLink).map(\.target).allSatisfy { $0.hasSuffix("/store-links/\(links[1].id)") })
    let onServer = try await linksOnServer(item.id, as: person)
    #expect(onServer.map { $0["price_minor"].number } == [4000, 2800])
  }

  @Test("A link removed elsewhere while the sheet is open gets no change from a Save that edited its price")
  func removedElsewhere() async throws {
    let (person, item) = try await person(withItem: "Kite", links: twoShops)
    let session = try await signedIn(as: person)
    let links = session.storeLinks(ofItem: item.id)
    let opened = try await draft(of: item.id, in: session)

    // Meanwhile, another device removes the first link, and a sync brings it.
    try await person.signedIn().send("DELETE", "/items/\(item.id)/store-links/\(links[0].id)").expecting(204)
    await session.syncNow()
    await until { session.storeLinks(ofItem: item.id).map(\.id) == [links[1].id] }

    var draft = opened
    draft.storeLinks[0].priceMinor = 1111
    draft.storeLinks[1].priceMinor = 2222
    await session.editItem(item.id, from: opened, to: draft)
    #expect(session.unsentChangeCount == 1)
    await until { session.unsentChangeCount == 0 }

    #expect(seen(Self.updateLink).map(\.target).allSatisfy { $0.hasSuffix("/store-links/\(links[1].id)") })
    #expect(session.lateRefusals.isEmpty)
    let onServer = try await linksOnServer(item.id, as: person)
    #expect(onServer.map { $0["price_minor"].number } == [2222])
  }

  // MARK: - 5. Remove

  @Test("Remove is an unsent change: the link goes at once, and the server deletes it, and the item keeps its price")
  func remove() async throws {
    let (person, item) = try await person(withItem: "Kite", links: twoShops)
    let session = try await signedIn(as: person)
    let links = session.storeLinks(ofItem: item.id)
    // The item took the first link's price.
    #expect(session.item(id: item.id)?.priceMinor == 2500)

    let hold = instance.conditioner.hold(Self.deleteLink, at: .request)
    let opened = try await draft(of: item.id, in: session)
    var draft = opened
    draft.removeStoreLink(links[0].id)
    #expect(draft.storeLinks.map(\.id) == [links[1].id])
    await session.editItem(item.id, from: opened, to: draft)

    #expect(session.storeLinks(ofItem: item.id).map(\.id) == [links[1].id])
    #expect(session.itemPage(id: item.id)?.storeLinks.map(\.id) == [links[1].id])
    #expect(session.copyLink(ofItem: item.id)?.absoluteString == links[1].url)
    #expect(session.unsentChangeCount == 1)

    await hold.waitUntilHeld()
    hold.release()
    await until { session.unsentChangeCount == 0 }
    let deletes = seen(Self.deleteLink)
    #expect(deletes.map(\.target) == ["\(TestServer.apiPrefix)/items/\(item.id)/store-links/\(links[0].id)"])
    #expect(deletes.first?.headers["idempotency-key"] != nil)
    #expect(deletes.first?.headers["if-match"] == nil)
    let saved = try await onServer(item.id, as: person)
    #expect(saved["store_links"].array?.map { $0["id"].string } == [links[1].id])
    #expect(saved["price_minor"].number == 2500)
    try await untilInStep(session, as: person)
    #expect(session.storeLinks(ofItem: item.id).map(\.id) == [links[1].id])
    #expect(session.item(id: item.id)?.priceMinor == 2500)
  }

  @Test(
    """
    A price edit and a Remove that the server refuses later are rolled back, show once as the item's edit, and are \
    captured by their route and code
    """
  )
  func refusedLate() async throws {
    let builder = instance.builder
    let robin = try await builder.person("Robin")
    let morgan = try await builder.person("Morgan")
    _ = try await builder.group("Family", users: [robin, morgan])
    let lego = try await builder.list("Lego", of: morgan)
    let bricks = try await builder.item("Bricks", on: lego, as: morgan, storeLinks: twoShops)
    try await builder.accept(try await builder.invite(robin, to: lego, as: morgan))
    let diagnostics = RecordingDiagnostics()
    let session = try await signedIn(as: robin, diagnostics: diagnostics)
    let links = session.storeLinks(ofItem: bricks.id)
    #expect(links.count == 2)

    instance.conditioner.dropEverything()
    let opened = try await draft(of: bricks.id, in: session)
    var draft = opened
    draft.storeLinks[0].priceMinor = 100
    draft.removeStoreLink(links[1].id)
    await session.editItem(bricks.id, from: opened, to: draft)
    #expect(session.storeLinks(ofItem: bricks.id).map(\.priceMinor) == [100])
    await until { session.isInstanceUnreachable }
    // Meanwhile, Robin leaves the list in a browser. They still see it, through the group, as a giver.
    try await robin.signedIn().send("DELETE", "/lists/\(lego.id)/recipients/\(robin.id)").expecting(204)

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }

    // Rolled back: both links are back, with the server's prices.
    await until { session.storeLinks(ofItem: bricks.id).count == 2 }
    #expect(Set(session.storeLinks(ofItem: bricks.id).map(\.priceMinor)) == [2500, 3000])
    #expect(try await linksOnServer(bricks.id, as: morgan).count == 2)
    await until { session.lateRefusals.count == 2 }
    #expect(
      diagnostics.faults == [
        .refusedWrite(.updateStoreLink, code: "forbidden"), .refusedWrite(.deleteStoreLink, code: "forbidden"),
      ])
    await session.cameToForeground(window: window)
    let alert = try #require(session.lateRefusalAlert)
    #expect(alert.refusals.map(\.title) == ["Bricks", "Bricks"])
    #expect(alert.refusals.map(\.refusal.route) == [.updateStoreLink, .deleteStoreLink])
    #expect(alert.refusals.last?.action == .deleteStoreLink(itemID: bricks.id, storeLinkID: links[1].id))
    session.lateRefusalsShown(in: window)
  }

  // MARK: - 6. Refresh prices

  @Test("Refresh prices comes only from can_refresh_prices: a giver is offered none, and asking sends nothing")
  func refreshOnlyFromCanRefreshPrices() async throws {
    let builder = instance.builder
    let owner = try await builder.person("Avery")
    let giver = try await builder.person("Blake")
    _ = try await builder.group("Pair", users: [owner, giver])
    let list = try await builder.list("Trip", of: owner)
    let item = try await builder.item("Map", on: list, as: owner, storeLinks: [twoShops[0]])
    let session = try await signedIn(as: giver)
    #expect(session.storeLinks(ofItem: item.id).count == 1)
    #expect(session.item(id: item.id)?.canRefreshPrices == false)
    #expect(!session.offersRefreshPrices(onItem: item.id))
    #expect(await session.refreshPrices(ofItem: item.id) == .failed)
    #expect(seen(Self.refresh).isEmpty)
  }

  @Test("Refresh prices gives the new prices, and when each was read, at once")
  func refreshPrices() async throws {
    let page = try await StorePage(title: "Kite \(instance.builder.tag)", priceMinor: 2499)
    let builder = instance.builder
    let robin = try await builder.person("Robin")
    let list = try await builder.primaryList(of: robin)
    // Two prices typed by hand, which the page doesn't have: one at the page's address, and one at another address
    // of the same page.
    let item = try await builder.item(
      "Kite", on: list, as: robin, storeLinks: [(page.url.absoluteString, 1000), (page.url.absoluteString + "?b", 700)])

    let session = try await signedIn(as: robin)
    let before = session.storeLinks(ofItem: item.id)
    let itemPrice = session.item(id: item.id)?.priceMinor
    #expect(before.map(\.priceMinor) == [1000, 700])
    #expect(session.item(id: item.id)?.canRefreshPrices == true)
    #expect(session.offersRefreshPrices(onItem: item.id))

    let asked = Date.now
    #expect(await session.refreshPrices(ofItem: item.id) == .checked)

    // At once, before any sync: the page's price on both links, each read just now. The server keeps whole seconds.
    let after = session.storeLinks(ofItem: item.id)
    #expect(after.map(\.id) == before.map(\.id))
    #expect(after.map(\.priceMinor) == [2499, 2499])
    #expect(after.allSatisfy { ($0.capturedAt ?? .distantPast) >= asked.addingTimeInterval(-1) })
    // The item's own price is never changed by a refresh.
    #expect(session.item(id: item.id)?.priceMinor == itemPrice)
    #expect(session.unsentChangeCount == 0)
    let requests = seen(Self.refresh)
    #expect(requests.count == 1)
    #expect(requests.first?.headers["idempotency-key"] != nil)
    #expect(page.reads == 2)
    let onServer = try await linksOnServer(item.id, as: robin)
    #expect(onServer.map { $0["price_minor"].number } == [2499, 2499])
    // The next sync keeps them.
    await session.syncNow()
    try await untilInStep(session, as: robin)
    #expect(session.storeLinks(ofItem: item.id).map(\.priceMinor) == [2499, 2499])
  }

  // MARK: - An item that waits to be created

  @Test(
    """
    An item that waits to be created offers no price edit, Remove or Refresh prices for its link, and Add link \
    sends its create first, then adds the link to the server's ID
    """
  )
  func standIn() async throws {
    let page = try await StorePage(title: "Kite \(instance.builder.tag)", priceMinor: 2499)
    let person = try await instance.person("Robin")
    let session = try await signedIn(as: person)
    instance.conditioner.dropEverything()
    let shop = "https://shop-\(instance.builder.tag).example/kite"
    var form = ItemDraft(given: .link(shop, store: "shop-\(instance.builder.tag).example"))
    form.title = "Kite \(instance.builder.tag)"
    form.priceMinor = 1500
    guard case .added(let created) = await session.add(&form) else {
      Issue.record("The add gave no item")
      return
    }
    #expect(StandIn.isStandIn(created.id))
    #expect(session.unsentChangeCount == 1)

    // The link shows, with no price edit and no Remove: the server's ID of the link isn't known yet.
    let opened = try await draft(of: created.id, in: session)
    #expect(opened.storeLinks.count == 1)
    #expect(opened.storeLinks.allSatisfy { !$0.canEdit && !$0.canDelete })
    var draft = opened
    draft.storeLinks[0].priceMinor = 900
    await session.editItem(created.id, from: opened, to: draft)
    draft.removeStoreLink(opened.storeLinks[0].id)
    await session.editItem(created.id, from: opened, to: draft)
    #expect(session.unsentChangeCount == 1)
    #expect(session.storeLinks(ofItem: created.id).map(\.url) == [shop])
    #expect(!session.offersRefreshPrices(onItem: created.id))
    #expect(await session.refreshPrices(ofItem: created.id) == .failed)

    // Add link waits for the server, which doesn't have the item yet, and can't reach it.
    #expect(await session.addStoreLink(page.url.absoluteString, toItem: created.id) == .unreachable)
    #expect(session.unsentChangeCount == 1)
    #expect(session.storeLinks(ofItem: created.id).count == 1)

    // With the instance back, Add link sends the create first, then adds the link to the item by the server's ID.
    instance.conditioner.passEverything()
    let sent = instance.conditioner.requests.count
    let link = try added(await session.addStoreLink(page.url.absoluteString, toItem: created.id))
    let serverID = session.serverID(of: created.id)
    #expect(!StandIn.isStandIn(serverID))
    let order = instance.conditioner.requests[sent...].compactMap { request in
      [Self.create, Self.addLink].firstIndex { request.isOn($0) }
    }
    #expect(order == [0, 1])
    #expect(
      seen(Self.addLink, from: sent).first?.target.hasPrefix("\(TestServer.apiPrefix)/items/\(serverID)/") == true)
    #expect(session.storeLinks(ofItem: created.id).map(\.id).last == link.id)
    #expect(session.storeLinks(ofItem: created.id).count == 2)
    let saved = try await linksOnServer(serverID, as: person)
    #expect(saved.compactMap { $0["id"].string }.last == link.id)
    #expect(saved.count == 2)
    #expect(session.unsentChangeCount == 0)

    // Once the server has the item, its links can be edited.
    let later = try await self.draft(of: created.id, in: session)
    #expect(later.storeLinks.allSatisfy { $0.canEdit && $0.canDelete })
    #expect(session.offersRefreshPrices(onItem: created.id))
  }
}
