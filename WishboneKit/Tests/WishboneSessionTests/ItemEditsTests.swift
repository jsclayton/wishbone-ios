import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// Edit item, and Delete, at the session model's seam, against the real server. Each is an unsent change: it shows
/// at once, in every window, and reaches the server, in order, with a new photo uploaded first. See "Edit item" and
/// Actions in `docs/screens/item.md`, and in `docs/spec.md`: "Unsent changes", and "A page that goes away under a
/// window".
@Suite("Editing and deleting an item", .timeLimit(.minutes(2)))
@MainActor
final class ItemEditsTests {
  typealias Route = NetworkConditioner.Route

  static let upload = Route("POST", "/images")
  static let create = Route("POST", "/lists/{id}/items")
  static let update = Route("PATCH", "/items/{id}")
  static let delete = Route("DELETE", "/items/{id}")

  let instance: Instance

  /// The one window of the app, as it comes to the foreground.
  let window = UUID()

  init() async throws {
    instance = try await Instance()
  }

  /// A device signed in as the person, through this test's conditioner, with the copy in step with the instance.
  private func signedIn(
    as person: Fixture.Person, storage: SessionStorage = .memory, diagnostics: any DiagnosticsReporter = .none
  ) async throws -> SessionModel {
    let device = instance.device(storage: storage, diagnostics: diagnostics)
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    try await untilInStep(session, as: person)
    return session
  }

  /// The item as the person reads it from the server.
  private func onServer(_ id: String, as person: Fixture.Person) async throws -> JSON {
    try await person.signedIn().get("/items/\(id)")
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

  /// A photo as the camera or the picker gives it.
  private func photo() throws -> Photo {
    try #require(
      Photo(
        file: try PhotoAddingTests.image(width: 64, height: 48, as: .png), untitled: PhotoAddingTests.untitled))
  }

  /// The draft of the item as the copy has it, as the sheet opens it.
  private func draft(of id: String, in session: SessionModel, sourceLocation: SourceLocation = #_sourceLocation)
    throws -> ItemEditDraft
  {
    ItemEditDraft(try #require(session.item(id: id), sourceLocation: sourceLocation))
  }

  // MARK: - 1. The title, the price and the notes

  @Test("An edit of the title, the price and the notes is one merge patch of those fields, and shows at once")
  func editFields() async throws {
    let person = try await instance.person("Robin", items: ["Scarf"])
    let session = try await signedIn(as: person)
    let item = try #require(session.primaryListItems.first)
    #expect(item.canEdit)

    // Held at the request, so what shows at once can't be the server's answer.
    let hold = instance.conditioner.hold(Self.update, at: .request)
    var draft = try self.draft(of: item.id, in: session)
    draft.title = "  A red scarf  "
    draft.priceMinor = 2499
    draft.notes = "Wool, please"
    await session.editItem(item.id, draft)

    let page = try #require(session.itemPage(id: item.id))
    #expect(page.item.title == "A red scarf")
    #expect(page.item.priceMinor == 2499)
    #expect(page.item.notes == "Wool, please")
    #expect(session.primaryListItems.first?.title == "A red scarf")
    #expect(session.unsentChangeCount == 1)

    await hold.waitUntilHeld()
    hold.release()
    await until { session.unsentChangeCount == 0 }
    let patches = seen(Self.update)
    #expect(patches.count == 1)
    let patch = try #require(patches.first)
    #expect(try fields(of: patch) == ["title", "price_minor", "notes"])
    #expect(patch.headers["idempotency-key"] != nil)
    #expect(patch.headers["if-match"] == nil)
    let body = try JSON(parsing: patch.body)
    #expect(body["title"].string == "A red scarf")
    #expect(body["price_minor"].number == 2499)
    #expect(body["notes"].string == "Wool, please")

    let saved = try await onServer(item.id, as: person)
    #expect(saved["title"].string == "A red scarf")
    #expect(saved["price_minor"].number == 2499)
    #expect(saved["notes"].string == "Wool, please")
    await until { session.item(id: item.id)?.version != item.version }
    #expect(session.item(id: item.id)?.title == "A red scarf")

    // A draft that changes nothing saves nothing.
    await session.editItem(item.id, try self.draft(of: item.id, in: session))
    #expect(session.unsentChangeCount == 0)
    #expect(seen(Self.update).count == 1)
  }

  // MARK: - 2. A cleared price

  @Test("A cleared price is sent as null with its top price, stays cleared through a relaunch, and after the pull")
  func clearedPrice() async throws {
    let builder = instance.builder
    let person = try await builder.person("Robin")
    let list = try await builder.primaryList(of: person)
    let item = try await builder.item("Lamp", on: list, as: person)
    try await person.signedIn().send(
      "PATCH", "/items/\(item.id)", json: ["price_minor": .number(2000), "top_price_minor": .number(3500)]
    ).expecting(200)
    let folder = try ScratchDirectory("device")
    do {
      let session = try await signedIn(as: person, storage: .folder(folder.url))
      #expect(session.item(id: item.id)?.topPriceMinor == 3500)
      instance.conditioner.dropEverything()
      var draft = try self.draft(of: item.id, in: session)
      draft.priceMinor = nil
      await session.editItem(item.id, draft)
      let shown = try #require(session.item(id: item.id))
      #expect(shown.priceMinor == nil)
      #expect(shown.topPriceMinor == nil)
      await until { session.isInstanceUnreachable }
    }

    // The journal reads the null back: the price is still cleared after a relaunch.
    let session = try #require(instance.device(storage: .folder(folder.url)).session)
    #expect(session.item(id: item.id)?.priceMinor == nil)
    #expect(session.unsentChangeCount == 1)

    instance.conditioner.passEverything()
    let sent = instance.conditioner.requests.count
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    let patch = try #require(seen(Self.update, from: sent).first)
    #expect(try fields(of: patch) == ["price_minor", "top_price_minor"])
    let body = try JSON(parsing: patch.body)
    #expect(body["price_minor"].isNull)
    #expect(body["top_price_minor"].isNull)
    let saved = try await onServer(item.id, as: person)
    #expect(saved["price_minor"].isNull)
    #expect(saved["top_price_minor"].isNull)
    try await untilInStep(session, as: person)
    #expect(session.item(id: item.id)?.priceMinor == nil)
    #expect(session.item(id: item.id)?.topPriceMinor == nil)
  }

  // MARK: - 3. How many

  @Test("How many, and Always wanted, show at once and reach the server, and the switch goes back to a count")
  func howMany() async throws {
    let person = try await instance.person("Robin", items: ["Socks"])
    let session = try await signedIn(as: person)
    let item = try #require(session.primaryListItems.first)
    #expect(session.itemPage(id: item.id)?.wanted == .count(1))

    var draft = try self.draft(of: item.id, in: session)
    draft.quantity = 3
    await session.editItem(item.id, draft)
    #expect(session.itemPage(id: item.id)?.wanted == .count(3))
    await until { session.unsentChangeCount == 0 }
    #expect(try await onServer(item.id, as: person)["quantity"].number == 3)

    draft = try self.draft(of: item.id, in: session)
    draft.isUnlimited = true
    await session.editItem(item.id, draft)
    #expect(session.itemPage(id: item.id)?.wanted == .always)
    await until { session.unsentChangeCount == 0 }
    #expect(try await onServer(item.id, as: person)["is_unlimited"].bool == true)
    #expect(try fields(of: try #require(seen(Self.update).last)) == ["is_unlimited"])

    draft = try self.draft(of: item.id, in: session)
    #expect(draft.quantity == 3)
    draft.isUnlimited = false
    draft.quantity = 2
    await session.editItem(item.id, draft)
    #expect(session.itemPage(id: item.id)?.wanted == .count(2))
    await until { session.unsentChangeCount == 0 }
    let saved = try await onServer(item.id, as: person)
    #expect(saved["is_unlimited"].bool == false)
    #expect(saved["quantity"].number == 2)
  }

  @Test("A parent who sees the claim state sees how many are still wanted move with how many are wanted")
  func stillWantedMoves() async throws {
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.primaryList(of: family.child)
    let item = try await builder.item("Kite", on: list, as: family.child, quantity: 2)
    let session = try await signedIn(as: family.parent)
    #expect(session.itemPage(id: item.id)?.stillWanted == .count(2, of: 2))

    instance.conditioner.dropEverything()
    var draft = try self.draft(of: item.id, in: session)
    draft.quantity = 4
    await session.editItem(item.id, draft)
    #expect(session.itemPage(id: item.id)?.stillWanted == .count(4, of: 4))
    draft.isUnlimited = true
    await session.editItem(item.id, draft)
    #expect(session.itemPage(id: item.id)?.stillWanted == .always)
    #expect(session.itemPage(id: item.id)?.wanted == .always)
  }

  // MARK: - 4. Photos

  @Test(
    """
    A photo is added, one is removed, and another is made the primary image: the upload goes first, then one patch \
    with the images in order. A sixth photo can't be added
    """
  )
  func photos() async throws {
    let builder = instance.builder
    let person = try await builder.person("Robin")
    let list = try await builder.primaryList(of: person)
    let first = try await builder.image(as: person)
    let second = try await builder.image(as: person)
    let third = try await builder.image(as: person)
    let item = try await builder.item("Mug", on: list, as: person, imageIDs: [first, second, third])
    let session = try await signedIn(as: person)
    let photo = try photo()

    var draft = try self.draft(of: item.id, in: session)
    #expect(draft.photos.map(\.id) == [first, second, third])
    #expect(draft.primaryID == first)
    draft.remove(second)
    draft.add(photo)
    draft.makePrimary(third)
    #expect(draft.photos.count == 3)
    #expect(draft.primaryID == third)

    let hold = instance.conditioner.hold(Self.upload, at: .request)
    let sent = instance.conditioner.requests.count
    await session.editItem(item.id, draft)
    // At once: the removed image is gone, and the primary image is the one picked. The new photo shows when the
    // server has it.
    let page = try #require(session.itemPage(id: item.id))
    #expect(page.images.map(\.id) == [third, first])
    #expect(session.item(id: item.id)?.primaryImage?.id == third)
    // One change, for the user: the upload goes with its edit.
    #expect(session.unsentChangeCount == 1)

    await hold.waitUntilHeld()
    hold.release()
    await until { session.unsentChangeCount == 0 }

    let uploads = seen(Self.upload, from: sent)
    let patches = seen(Self.update, from: sent)
    #expect(uploads.count == 1)
    #expect(patches.count == 1)
    let requests = Array(instance.conditioner.requests[sent...])
    let upload = try #require(requests.firstIndex { $0.isOn(Self.upload) })
    let patch = try #require(requests.firstIndex { $0.isOn(Self.update) })
    #expect(upload < patch)
    #expect(requests[upload].body == photo.data)
    #expect(try fields(of: requests[patch]) == ["image_ids", "primary_image_id"])

    let saved = try await onServer(item.id, as: person)
    let ids = try #require(saved["images"].array?.compactMap { $0["id"].string })
    #expect(ids.count == 3)
    #expect(Array(ids.prefix(2)) == [first, third])
    let added = try #require(ids.last)
    #expect(!StandIn.isStandIn(added))
    #expect(saved["primary_image"]["id"].string == third)
    let body = try JSON(parsing: requests[patch].body)
    #expect(body["image_ids"].array?.compactMap(\.string) == [first, third, added])
    #expect(body["primary_image_id"].string == third)
    // The new photo shows, and the image cache holds its bytes already.
    await until { session.item(id: item.id)?.images.map(\.id) == [first, third, added] }
    let image = try #require(session.item(id: item.id)?.images.last)
    #expect(session.images.cached(image) == photo.data)

    // A sixth photo can't be added: the draft keeps five.
    var full = try self.draft(of: item.id, in: session)
    full.add(try self.photo())
    full.add(try self.photo())
    #expect(full.photos.count == 5)
    #expect(!full.canAddPhoto)
    full.add(try self.photo())
    #expect(full.photos.count == 5)
  }

  @Test(
    "Removing the primary photo makes the first one left the primary, and removing every photo sends an empty array")
  func removePrimary() async throws {
    let builder = instance.builder
    let person = try await builder.person("Robin")
    let list = try await builder.primaryList(of: person)
    let first = try await builder.image(as: person)
    let second = try await builder.image(as: person)
    let item = try await builder.item("Vase", on: list, as: person, imageIDs: [first, second])
    let session = try await signedIn(as: person)

    var draft = try self.draft(of: item.id, in: session)
    draft.remove(first)
    #expect(draft.primaryID == second)
    await session.editItem(item.id, draft)
    #expect(session.item(id: item.id)?.primaryImage?.id == second)
    await until { session.unsentChangeCount == 0 }
    #expect(try await onServer(item.id, as: person)["primary_image"]["id"].string == second)

    draft = try self.draft(of: item.id, in: session)
    draft.remove(second)
    #expect(draft.primaryID == nil)
    await session.editItem(item.id, draft)
    #expect(session.itemPage(id: item.id)?.images.isEmpty == true)
    await until { session.unsentChangeCount == 0 }
    let body = try JSON(parsing: try #require(seen(Self.update).last).body)
    #expect(body["image_ids"].array?.isEmpty == true)
    #expect(try await onServer(item.id, as: person)["images"].array?.isEmpty == true)
  }

  @Test("A new photo that the server refuses late shows once, and the edit is saved without it")
  func photoRefusedLate() async throws {
    let person = try await instance.person("Robin", items: ["Lamp"])
    let folder = try ScratchDirectory("device")
    let session = try await signedIn(as: person, storage: .folder(folder.url))
    let item = try #require(session.primaryListItems.first)
    instance.conditioner.dropEverything()
    var draft = try self.draft(of: item.id, in: session)
    draft.title = "Desk lamp"
    // Bytes that the server can't read as an image stand in for a photo that it refuses.
    draft.add(Photo(data: Data("not a photo".utf8), untitled: "Photo"))
    await session.editItem(item.id, draft)
    #expect(try DatabaseFile(under: folder.url).count(of: "unsentFile") == 1)
    await until { session.isInstanceUnreachable }

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }

    let saved = try await onServer(item.id, as: person)
    #expect(saved["title"].string == "Desk lamp")
    #expect(saved["images"].array?.isEmpty == true)
    #expect(try DatabaseFile(under: folder.url).count(of: "unsentFile") == 0)
    await until { session.lateRefusals.count == 1 }
    #expect(session.lateRefusals.first?.refusal.code == .imageInvalid)
    #expect(session.lateRefusals.first?.title == "Lamp")
  }

  // MARK: - 5. With the network dropped, in order

  @Test(
    """
    With the network dropped: an item added by hand, an edit of it with a new photo, and a delete of another item \
    show at once. When it is back, each lands once, in order: the create, the upload, the edit, the delete
    """
  )
  func offlineInOrder() async throws {
    let person = try await instance.person("Robin", items: ["Ball"])
    let session = try await signedIn(as: person)
    let list = try #require(session.primaryList)
    let ball = try #require(session.primaryListItems.first)
    let title = "Kite \(instance.builder.tag)"
    instance.conditioner.dropEverything()

    var form = ItemDraft(given: .words(title))
    form.listID = list.id
    guard case .added(let added) = await session.add(&form) else {
      Issue.record("The add gave no item")
      return
    }
    #expect(StandIn.isStandIn(added.id))
    let created = try #require(session.item(id: added.id))
    #expect(created.canEdit)
    #expect(created.canDelete)

    // The edit names the item by its stand-in ID.
    var draft = ItemEditDraft(created)
    draft.title = "Box kite"
    draft.priceMinor = 1500
    draft.quantity = 2
    let photo = try photo()
    draft.add(photo)
    await session.editItem(added.id, draft)
    await session.deleteItem(ball.id)

    // At once: the edit over the item that waits to be created, and the other item gone.
    #expect(session.items(onList: list.id).map(\.title) == ["Box kite"])
    #expect(session.itemPage(id: added.id)?.item.priceMinor == 1500)
    #expect(session.itemPage(id: added.id)?.wanted == .count(2))
    #expect(session.itemPage(id: ball.id) == nil)
    #expect(session.list(id: list.id)?.itemCount == 1)
    // The create, the edit and the delete. The upload goes with its edit.
    #expect(session.unsentChangeCount == 3)
    await until { session.isInstanceUnreachable }

    instance.conditioner.passEverything()
    let sent = instance.conditioner.requests.count
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }

    let requests = instance.conditioner.requests[sent...].filter { request in
      [Self.create, Self.upload, Self.update, Self.delete].contains { request.isOn($0) }
    }
    #expect(requests.count == 4)
    let order = requests.map { request in
      [Self.create, Self.upload, Self.update, Self.delete].firstIndex { request.isOn($0) } ?? -1
    }
    #expect(order == [0, 1, 2, 3])
    let serverID = session.serverID(of: added.id)
    #expect(!StandIn.isStandIn(serverID))
    #expect(requests[2].target.hasSuffix("/items/\(serverID)"))
    #expect(requests[3].target.hasSuffix("/items/\(ball.id)"))

    let saved = try await onServer(serverID, as: person)
    #expect(saved["title"].string == "Box kite")
    #expect(saved["price_minor"].number == 1500)
    #expect(saved["quantity"].number == 2)
    #expect(saved["images"].array?.count == 1)
    #expect(try await person.signedIn().status(of: "/items/\(ball.id)") == 404)
    #expect(session.lateRefusals.isEmpty)

    // Each landed once: later syncs send nothing.
    await session.syncNow()
    #expect(instance.conditioner.requests[sent...].count { $0.isOn(Self.update) } == 1)
    let onList = try await person.signedIn().all("/lists/\(list.id)/items")
    #expect(onList.compactMap { $0["title"].string } == ["Box kite"])
    try await untilInStep(session, as: person)
    #expect(session.items(onList: list.id).map(\.id) == [serverID])
  }

  @Test("A delete of an item that waits to be created is sent after its create, by the server's ID")
  func deleteStandIn() async throws {
    let person = try await instance.person("Robin")
    let session = try await signedIn(as: person)
    let list = try #require(session.primaryList)
    instance.conditioner.dropEverything()
    var form = ItemDraft(given: .words("Yo-yo \(instance.builder.tag)"))
    guard case .added(let added) = await session.add(&form) else {
      Issue.record("The add gave no item")
      return
    }
    await session.deleteItem(added.id)
    #expect(session.item(id: added.id) == nil)
    #expect(session.items(onList: list.id).isEmpty)
    #expect(session.list(id: list.id)?.itemCount == 0)
    await until { session.isInstanceUnreachable }

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    let serverID = session.serverID(of: added.id)
    #expect(!StandIn.isStandIn(serverID))
    #expect(seen(Self.delete).map(\.target).allSatisfy { $0.hasSuffix("/items/\(serverID)") })
    #expect(seen(Self.delete).count == 1)
    #expect(try await person.signedIn().all("/lists/\(list.id)/items").isEmpty)
    #expect(session.lateRefusals.isEmpty)
  }

  @Test(
    """
    A create that the server refuses late takes the edit and the delete of its item with it, and the upload of the \
    edit's photo: only the create's refusal shows
    """
  )
  func refusedCreateTakesItsChanges() async throws {
    let builder = instance.builder
    let robin = try await builder.person("Robin")
    let morgan = try await builder.person("Morgan")
    _ = try await builder.group("Family", users: [robin, morgan])
    let lego = try await builder.list("Lego", of: morgan)
    try await builder.accept(try await builder.invite(robin, to: lego, as: morgan))
    let folder = try ScratchDirectory("device")
    let session = try await signedIn(as: robin, storage: .folder(folder.url))

    instance.conditioner.dropEverything()
    var form = ItemDraft(given: .words("Bricks \(builder.tag)"))
    form.listID = lego.id
    guard case .added(let added) = await session.add(&form) else {
      Issue.record("The add gave no item")
      return
    }
    var draft = try self.draft(of: added.id, in: session)
    draft.title = "More bricks"
    draft.add(try photo())
    await session.editItem(added.id, draft)
    await session.deleteItem(added.id)
    #expect(session.unsentChangeCount == 3)
    #expect(try DatabaseFile(under: folder.url).count(of: "unsentFile") == 1)
    await until { session.isInstanceUnreachable }
    // Meanwhile, Robin leaves the list in a browser, so the create is refused.
    try await robin.signedIn().send("DELETE", "/lists/\(lego.id)/recipients/\(robin.id)").expecting(204)

    instance.conditioner.passEverything()
    let sent = instance.conditioner.requests.count
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    await until { session.lateRefusals.count == 1 }
    guard case .createItem = session.lateRefusals.first?.action else {
      Issue.record("The refusal was of \(String(describing: session.lateRefusals.first?.action))")
      return
    }
    // Nothing named the stand-in to the server, and the photo was never sent.
    #expect(seen(Self.upload, from: sent).isEmpty)
    #expect(seen(Self.update, from: sent).isEmpty)
    #expect(seen(Self.delete, from: sent).isEmpty)
    #expect(try DatabaseFile(under: folder.url).count(of: "unsentFile") == 0)
  }

  // MARK: - 6. Delete

  @Test("Delete takes the item out at once: another window that shows its page shows not found")
  func delete() async throws {
    let person = try await instance.person("Robin", items: ["Ball", "Bat"])
    let session = try await signedIn(as: person)
    let list = try #require(session.primaryList)
    let ball = try #require(session.primaryListItems.first)
    #expect(ball.canDelete)
    #expect(session.list(id: list.id)?.itemCount == 2)

    // Offline, so that what shows at once can't be the server's.
    instance.conditioner.dropEverything()
    await session.deleteItem(ball.id)

    // Every window reads the one copy: the item's page is the "not found" page.
    #expect(session.itemPage(id: ball.id) == nil)
    #expect(session.item(id: ball.id) == nil)
    #expect(session.items(onList: list.id).map(\.title) == ["Bat"])
    #expect(session.list(id: list.id)?.itemCount == 1)
    #expect(session.unsentChangeCount == 1)
    await until { session.isInstanceUnreachable }

    // The pull after the delete waits, so the copy shows what the delete's answer left: the item doesn't come back.
    instance.conditioner.passEverything()
    let pull = instance.conditioner.hold(Route("GET", "/versions"), at: .request)
    let syncing = Task { await session.syncNow() }
    await pull.waitUntilHeld()
    await until { session.unsentChangeCount == 0 }
    #expect(session.item(id: ball.id) == nil)
    #expect(session.items(onList: list.id).map(\.title) == ["Bat"])
    pull.release()
    _ = await syncing.value
    #expect(try await person.signedIn().status(of: "/items/\(ball.id)") == 404)
    try await untilInStep(session, as: person)
    #expect(session.itemPage(id: ball.id) == nil)
    #expect(session.list(id: list.id)?.itemCount == 1)
    #expect(session.lateRefusals.isEmpty)
    let delete = try #require(seen(Self.delete).first)
    #expect(delete.headers["idempotency-key"] != nil)
    #expect(delete.headers["if-match"] == nil)
  }

  @Test("Edit and Delete come only from can_edit and can_delete: a giver can do neither")
  func onlyFromCanFields() async throws {
    let builder = instance.builder
    let owner = try await builder.person("Avery")
    let giver = try await builder.person("Blake")
    _ = try await builder.group("Pair", users: [owner, giver])
    let list = try await builder.list("Trip", of: owner)
    let item = try await builder.item("Map", on: list, as: owner)
    let session = try await signedIn(as: giver)
    let row = try #require(session.item(id: item.id))
    #expect(!row.canEdit)
    #expect(!row.canDelete)

    var draft = ItemEditDraft(row)
    draft.title = "Atlas"
    await session.editItem(item.id, draft)
    await session.deleteItem(item.id)
    #expect(session.unsentChangeCount == 0)
    #expect(session.item(id: item.id)?.title == "Map")
  }

  // MARK: - 7. A late refusal

  @Test(
    """
    An edit and a delete that the server refuses later are rolled back, show once, and are captured by their route \
    and code
    """
  )
  func refusedLate() async throws {
    let builder = instance.builder
    let robin = try await builder.person("Robin")
    let morgan = try await builder.person("Morgan")
    _ = try await builder.group("Family", users: [robin, morgan])
    let lego = try await builder.list("Lego", of: morgan)
    let bricks = try await builder.item("Bricks", on: lego, as: morgan)
    let plates = try await builder.item("Plates", on: lego, as: morgan)
    try await builder.accept(try await builder.invite(robin, to: lego, as: morgan))
    let diagnostics = RecordingDiagnostics()
    let session = try await signedIn(as: robin, diagnostics: diagnostics)
    #expect(session.item(id: bricks.id)?.canEdit == true)

    instance.conditioner.dropEverything()
    var draft = try self.draft(of: bricks.id, in: session)
    draft.title = "Big bricks"
    await session.editItem(bricks.id, draft)
    await session.deleteItem(plates.id)
    #expect(session.item(id: bricks.id)?.title == "Big bricks")
    #expect(session.item(id: plates.id) == nil)
    await until { session.isInstanceUnreachable }
    // Meanwhile, Robin leaves the list in a browser. They still see it, through the group, as a giver.
    try await robin.signedIn().send("DELETE", "/lists/\(lego.id)/recipients/\(robin.id)").expecting(204)

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }

    // Rolled back: the title is the server's, and the other item is back.
    await until { session.item(id: bricks.id)?.title == "Bricks" }
    await until { session.item(id: plates.id) != nil }
    #expect(try await onServer(bricks.id, as: morgan)["title"].string == "Bricks")
    await until { session.lateRefusals.count == 2 }
    #expect(
      diagnostics.faults == [
        .refusedWrite(.updateItem, code: "forbidden"), .refusedWrite(.deleteItem, code: "forbidden"),
      ])

    await session.cameToForeground(window: window)
    let alert = try #require(session.lateRefusalAlert)
    #expect(alert.refusals.map(\.title) == ["Bricks", "Plates"])
    #expect(alert.refusals.map(\.refusal.route) == [.updateItem, .deleteItem])
    #expect(alert.refusals.last?.action == .deleteItem(itemID: plates.id, listID: lego.id))
    session.lateRefusalsShown(in: window)
    session.leftForeground(window: window)
    await session.cameToForeground(window: window)
    #expect(session.lateRefusalAlert == nil)
  }

  // MARK: - 8. A title

  @Test("An empty title can't be saved")
  func emptyTitle() async throws {
    let person = try await instance.person("Robin", items: ["Scarf"])
    let session = try await signedIn(as: person)
    let item = try #require(session.primaryListItems.first)
    var draft = try self.draft(of: item.id, in: session)
    draft.title = "  \n "
    #expect(!draft.hasTitle)
    draft.notes = "Wool"
    await session.editItem(item.id, draft)
    #expect(session.unsentChangeCount == 0)
    #expect(session.item(id: item.id)?.title == "Scarf")
    #expect(session.item(id: item.id)?.notes == nil)
    #expect(seen(Self.update).isEmpty)
  }
}
