import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// Move to…, at the session model's seam, against the real server. A move is an unsent change: the item shows at the
/// end of the list picked at once, in every window, and reaches the server as `PATCH /items/{id}` with only
/// `list_id`. The copy takes the server's answer with its shift rule, and a refusal puts the item back. See "A drag
/// between lists is a move", "Every drag has a way without dragging", "What the windows show after a drop" and "A
/// page that goes away under a window" in `docs/spec.md`, and Move to… in `docs/screens/item.md` and
/// `docs/screens/list.md`.
@Suite("Moving an item to another list", .timeLimit(.minutes(2)))
@MainActor
final class MoveTests {
  typealias Route = NetworkConditioner.Route

  static let create = Route("POST", "/lists/{id}/items")
  static let update = Route("PATCH", "/items/{id}")
  static let delete = Route("DELETE", "/items/{id}")
  static let versions = Route("GET", "/versions")

  let instance: Instance

  /// The one window of the app, as it comes to the foreground.
  let window = UUID()

  init() async throws {
    instance = try await Instance()
  }

  /// A device signed in as the person, through this test's conditioner, with the copy in step with the instance.
  private func signedIn(
    as person: Fixture.Person, on instance: Instance? = nil, diagnostics: any DiagnosticsReporter = .none
  ) async throws -> SessionModel {
    let instance = instance ?? self.instance
    let device = instance.device(diagnostics: diagnostics)
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    try await untilInStep(session, as: person)
    return session
  }

  /// A person with their primary list and a second list, "Toys", each with the items given, in order.
  private func person(_ name: String, primary: [String], toys: [String]) async throws -> (
    person: Fixture.Person, primary: Fixture.List, toys: Fixture.List, items: [String: Fixture.Item]
  ) {
    let builder = instance.builder
    let person = try await builder.person(name)
    let primaryList = try await builder.primaryList(of: person)
    let toysList = try await builder.list("Toys", of: person)
    var items: [String: Fixture.Item] = [:]
    for title in primary {
      items[title] = try await builder.item(title, on: primaryList, as: person)
    }
    for title in toys {
      items[title] = try await builder.item(title, on: toysList, as: person)
    }
    return (person, primaryList, toysList, items)
  }

  /// The items of the list as the server has them for the person, by ID, with their positions.
  private func onServer(_ listID: String, as person: Fixture.Person) async throws -> [String: Int] {
    var places: [String: Int] = [:]
    for item in try await person.signedIn().all("/lists/\(listID)/items") {
      places[item["id"].string ?? ""] = item["position"].number.map { Int($0) }
    }
    return places
  }

  /// The items of the list as the copy shows them, by ID, with their positions.
  private func inCopy(_ listID: String, of session: SessionModel) -> [String: Int] {
    Dictionary(uniqueKeysWithValues: session.items(onList: listID).map { ($0.id, $0.position) })
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

  // MARK: - 2. The picker

  @Test(
    """
    Move to… offers the other lists the user can edit, a child's under the child with the child's name, and is \
    absent when no other list can take the item or the user can't edit it
    """
  )
  func picker() async throws {
    let builder = instance.builder
    let parent = try await builder.person("Dana")
    let child = try await builder.person("Emma", parents: [parent])
    let parentPrimary = try await builder.primaryList(of: parent)
    let house = try await builder.list("Our house", of: parent)
    let childPrimary = try await builder.primaryList(of: child)
    let grill = try await builder.item("Grill", on: house, as: parent)
    let kite = try await builder.item("Kite", on: childPrimary, as: child)
    let friend = try await builder.person("Avery")
    _ = try await builder.group("Pair", users: [parent, friend])
    let trip = try await builder.list("Trip", of: friend)
    let map = try await builder.item("Map", on: trip, as: friend)
    let session = try await signedIn(as: parent)

    let forGrill = try #require(session.moveTargets(ofItem: grill.id))
    #expect(forGrill.yourLists.map(\.id) == [parentPrimary.id])
    #expect(forGrill.yourLists.allSatisfy { $0.isMine && $0.recipientNames.isEmpty })
    #expect(forGrill.children.map(\.child.id) == [child.id])
    #expect(forGrill.children.first?.targets.map(\.id) == [childPrimary.id])
    #expect(forGrill.children.first?.targets.first?.recipientNames == [child.name])
    // The friend's list can't be edited, so it is never offered.
    #expect(!forGrill.targets.contains { $0.id == trip.id })

    // The child's item can go to the parent's lists, and to no other list of the child's: there is none.
    let forKite = try #require(session.moveTargets(ofItem: kite.id))
    #expect(forKite.yourLists.map(\.id) == [parentPrimary.id, house.id])
    #expect(forKite.children.isEmpty)

    // A giver can't edit the item: no Move to…, and a move does nothing.
    #expect(session.item(id: map.id)?.canEdit == false)
    #expect(session.moveTargets(ofItem: map.id) == nil)
    await session.moveItem(map.id, toList: parentPrimary.id)
    #expect(session.unsentChangeCount == 0)

    // A person whose only list is the item's: no Move to…. Another device, with a keychain of its own.
    let loner = try await instance.person("Sol", items: ["Ball"])
    let lonerSession = try await signedIn(as: loner, on: try await Instance())
    let ball = try #require(lonerSession.primaryListItems.first)
    #expect(ball.canEdit)
    #expect(lonerSession.moveTargets(ofItem: ball.id) == nil)
  }

  // MARK: - 3. At once, with only list_id

  @Test(
    """
    A move puts the item at the end of the list picked at once, in every window. The request has only list_id, a \
    key, and no If-Match, and the item's page stays, with the new list's name
    """
  )
  func atOnce() async throws {
    let robin = try await person("Robin", primary: ["Ball", "Bat", "Cap"], toys: ["Doll"])
    let bat = try #require(robin.items["Bat"])
    let session = try await signedIn(as: robin.person)
    #expect(session.itemPage(id: bat.id)?.list.id == robin.primary.id)

    // Held at the request, so what shows at once can't be the server's answer.
    let hold = instance.conditioner.hold(Self.update, at: .request)
    await session.moveItem(bat.id, toList: robin.toys.id)

    #expect(session.items(onList: robin.primary.id).map(\.title) == ["Ball", "Cap"])
    #expect(session.items(onList: robin.toys.id).map(\.title) == ["Doll", "Bat"])
    #expect(session.item(id: bat.id)?.position == 1)
    #expect(session.list(id: robin.primary.id)?.itemCount == 2)
    #expect(session.list(id: robin.toys.id)?.itemCount == 2)
    // 7. A window that shows the item's page shows it still, with the new list's name.
    let page = try #require(session.itemPage(id: bat.id))
    #expect(page.list.id == robin.toys.id)
    #expect(page.list.name == robin.toys.name)
    #expect(session.unsentChangeCount == 1)

    await hold.waitUntilHeld()
    hold.release()
    await until { session.unsentChangeCount == 0 }
    let patches = seen(Self.update)
    #expect(patches.count == 1)
    let patch = try #require(patches.first)
    #expect(patch.target.hasSuffix("/items/\(bat.id)"))
    #expect(try fields(of: patch) == ["list_id"])
    #expect(try JSON(parsing: patch.body)["list_id"].string == robin.toys.id)
    #expect(patch.headers["idempotency-key"] != nil)
    #expect(patch.headers["if-match"] == nil)

    let saved = try await robin.person.signedIn().get("/items/\(bat.id)")
    #expect(saved["list_id"].string == robin.toys.id)
    #expect(saved["position"].number == 1)
    try await untilInStep(session, as: robin.person)
    #expect(session.itemPage(id: bat.id)?.list.name == robin.toys.name)
    #expect(session.lateRefusals.isEmpty)

    // A move to the list that the item is on already does nothing.
    await session.moveItem(bat.id, toList: robin.toys.id)
    #expect(session.unsentChangeCount == 0)
  }

  // MARK: - 4. The shift rule against a fresh pull

  @Test("After the server accepts a move, and before the pull, the copy and the server agree on every position")
  func agreesWithAPull() async throws {
    let robin = try await person("Robin", primary: ["Ball", "Bat", "Cap", "Drum"], toys: ["Doll", "Eel"])
    let bat = try #require(robin.items["Bat"])
    let session = try await signedIn(as: robin.person)

    // The pull after the move waits, so the copy shows what the move's answer and the shift rule left.
    let pull = instance.conditioner.hold(Self.versions, at: .request)
    await session.moveItem(bat.id, toList: robin.toys.id)
    await pull.waitUntilHeld()
    await until { session.unsentChangeCount == 0 }

    let primary = try await onServer(robin.primary.id, as: robin.person)
    let toys = try await onServer(robin.toys.id, as: robin.person)
    #expect(Set(primary.values) == [0, 1, 2])
    #expect(toys[bat.id] == 2)
    #expect(inCopy(robin.primary.id, of: session) == primary)
    #expect(inCopy(robin.toys.id, of: session) == toys)
    // Each list counts as the server counts.
    for list in [robin.primary, robin.toys] {
      let count = try await robin.person.signedIn().get("/lists/\(list.id)")["item_count"].number
      #expect(session.list(id: list.id)?.itemCount == count.map { Int($0) })
    }

    pull.release()
    try await untilInStep(session, as: robin.person)
    #expect(inCopy(robin.primary.id, of: session) == primary)
    #expect(inCopy(robin.toys.id, of: session) == toys)
  }

  // MARK: - 5. A refusal

  @Test(
    """
    A move that the server refuses with cannot_edit_target_list puts the item back in its place, in every window, \
    shows in the window that moved it, and is captured by its code
    """
  )
  func refused() async throws {
    let builder = instance.builder
    let robin = try await instance.person("Robin", items: ["Ball", "Bat", "Cap"])
    let morgan = try await builder.person("Morgan")
    _ = try await builder.group("Family", users: [robin, morgan])
    let lego = try await builder.list("Lego", of: morgan)
    try await builder.accept(try await builder.invite(robin, to: lego, as: morgan))
    let diagnostics = RecordingDiagnostics()
    let session = try await signedIn(as: robin, diagnostics: diagnostics)
    let primary = try #require(session.primaryList)
    let bat = try #require(session.items(onList: primary.id).first { $0.title == "Bat" })
    await session.cameToForeground(window: window)
    #expect(session.moveTargets(ofItem: bat.id)?.targets.contains { $0.id == lego.id } == true)

    // Robin leaves Lego in a browser. They still see it, through the group, as a giver, and the copy doesn't know.
    try await robin.signedIn().send("DELETE", "/lists/\(lego.id)/recipients/\(robin.id)").expecting(204)
    let pull = instance.conditioner.hold(Self.versions, at: .request)
    await session.moveItem(bat.id, toList: lego.id, from: window)
    #expect(session.itemPage(id: bat.id)?.list.id == lego.id)

    // Rolled back before the pull: Bat is back in its place, and its page shows its own list again.
    await pull.waitUntilHeld()
    await until { session.unsentChangeCount == 0 }
    #expect(session.items(onList: primary.id).map(\.title) == ["Ball", "Bat", "Cap"])
    #expect(session.item(id: bat.id) == bat)
    #expect(session.itemPage(id: bat.id)?.list.id == primary.id)
    #expect(session.items(onList: lego.id).isEmpty)
    #expect(session.list(id: primary.id)?.itemCount == 3)
    pull.release()

    // The refusal shows at once, in the window that moved the item, and only once.
    await until { session.lateRefusalAlert != nil }
    let alert = try #require(session.lateRefusalAlert)
    #expect(alert.window == window)
    #expect(alert.refusals.map(\.title) == ["Bat"])
    let refusal = try #require(alert.refusals.first)
    #expect(refusal.refusal.code == .cannotEditTargetList)
    #expect(refusal.refusal.status == 403)
    guard case .moveItem(let move) = refusal.action else {
      Issue.record("The refusal was of \(refusal.action)")
      return
    }
    #expect(move.toListName == lego.name)
    #expect(diagnostics.faults == [.refusedWrite(.updateItem, code: "cannot_edit_target_list")])
    session.lateRefusalsShown(in: window)
    session.leftForeground(window: window)
    await session.cameToForeground(window: window)
    #expect(session.lateRefusalAlert == nil)
    #expect(try await robin.signedIn().get("/items/\(bat.id)")["list_id"].string == primary.id)
  }

  @Test("A move of an item that is gone from the server, a 404, puts it back until the pull, and is never captured")
  func refusedGone() async throws {
    let robin = try await person("Robin", primary: ["Ball", "Bat"], toys: ["Doll"])
    let bat = try #require(robin.items["Bat"])
    let diagnostics = RecordingDiagnostics()
    let session = try await signedIn(as: robin.person, diagnostics: diagnostics)
    // Deleted in a browser: the copy doesn't know.
    try await robin.person.signedIn().send("DELETE", "/items/\(bat.id)").expecting(204)

    let pull = instance.conditioner.hold(Self.versions, at: .request)
    await session.moveItem(bat.id, toList: robin.toys.id)
    await pull.waitUntilHeld()
    await until { session.unsentChangeCount == 0 }
    #expect(session.item(id: bat.id)?.listID == robin.primary.id)
    #expect(session.items(onList: robin.toys.id).map(\.title) == ["Doll"])
    pull.release()
    await until { session.item(id: bat.id) == nil }
    await until { session.lateRefusals.count == 1 }
    #expect(session.lateRefusals.first?.refusal.status == 404)
    #expect(diagnostics.faults.isEmpty)
  }

  // MARK: - 6. With the network dropped

  @Test("A move made with the network dropped waits, shows meanwhile, and is sent when the instance answers")
  func offline() async throws {
    let robin = try await person("Robin", primary: ["Ball", "Bat"], toys: ["Doll"])
    let bat = try #require(robin.items["Bat"])
    let session = try await signedIn(as: robin.person)
    instance.conditioner.dropEverything()

    await session.moveItem(bat.id, toList: robin.toys.id)
    #expect(session.items(onList: robin.toys.id).map(\.title) == ["Doll", "Bat"])
    await until { session.isInstanceUnreachable }
    #expect(session.unsentChangeCount == 1)
    #expect(session.items(onList: robin.toys.id).map(\.title) == ["Doll", "Bat"])
    #expect(try await robin.person.signedIn().get("/items/\(bat.id)")["list_id"].string == robin.primary.id)

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    #expect(try await robin.person.signedIn().get("/items/\(bat.id)")["list_id"].string == robin.toys.id)
    try await untilInStep(session, as: robin.person)
    #expect(session.items(onList: robin.toys.id).map(\.title) == ["Doll", "Bat"])
    #expect(session.items(onList: robin.primary.id).map(\.title) == ["Ball"])
    #expect(session.lateRefusals.isEmpty)
  }

  // MARK: - With other changes to the item

  @Test(
    """
    An item added with no connection, moved, then edited: the create, the move and the edit land once, in order, \
    and the server has one item, on the list picked, with the edit
    """
  )
  func moveOfAStandIn() async throws {
    let robin = try await person("Robin", primary: [], toys: ["Doll"])
    let session = try await signedIn(as: robin.person)
    let title = "Kite \(instance.builder.tag)"
    instance.conditioner.dropEverything()
    var form = ItemDraft(given: .words(title))
    form.listID = robin.primary.id
    guard case .added(let added) = await session.add(&form) else {
      Issue.record("The add gave no item")
      return
    }
    #expect(StandIn.isStandIn(added.id))
    #expect(session.moveTargets(ofItem: added.id) != nil)
    await session.moveItem(added.id, toList: robin.toys.id)
    let opened = try #require(await session.editDraft(ofItem: added.id))
    var draft = opened
    draft.title = "Box kite"
    await session.editItem(added.id, from: opened, to: draft)
    #expect(session.items(onList: robin.toys.id).map(\.title) == ["Doll", "Box kite"])
    #expect(session.items(onList: robin.primary.id).isEmpty)
    #expect(session.itemPage(id: added.id)?.list.id == robin.toys.id)
    await until { session.isInstanceUnreachable }

    instance.conditioner.passEverything()
    let sent = instance.conditioner.requests.count
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    let serverID = session.serverID(of: added.id)
    #expect(!StandIn.isStandIn(serverID))
    let requests = instance.conditioner.requests[sent...].filter { $0.isOn(Self.create) || $0.isOn(Self.update) }
    #expect(requests.count == 3)
    #expect(requests.map { $0.isOn(Self.create) } == [true, false, false])
    #expect(try requests.dropFirst().map(fields) == [["list_id"], ["title"]])
    #expect(requests.dropFirst().allSatisfy { $0.target.hasSuffix("/items/\(serverID)") })

    let toys = try await robin.person.signedIn().all("/lists/\(robin.toys.id)/items")
    #expect(toys.compactMap { $0["title"].string } == ["Doll", "Box kite"])
    #expect(try await robin.person.signedIn().all("/lists/\(robin.primary.id)/items").isEmpty)
    try await untilInStep(session, as: robin.person)
    #expect(session.items(onList: robin.toys.id).map(\.id).last == serverID)
    #expect(session.itemPage(id: added.id)?.list.id == robin.toys.id)
    #expect(session.lateRefusals.isEmpty)
  }

  @Test(
    """
    An edit, a move and another edit of one item, with no connection, land in order, each with only its own \
    fields: the server has the item on the list picked, with both edits
    """
  )
  func editsAroundAMove() async throws {
    let robin = try await person("Robin", primary: ["Ball", "Bat"], toys: ["Doll"])
    let bat = try #require(robin.items["Bat"])
    let session = try await signedIn(as: robin.person)
    instance.conditioner.dropEverything()

    let first = try #require(await session.editDraft(ofItem: bat.id))
    var titled = first
    titled.title = "Big bat"
    await session.editItem(bat.id, from: first, to: titled)
    await session.moveItem(bat.id, toList: robin.toys.id)
    let second = try #require(await session.editDraft(ofItem: bat.id))
    var noted = second
    noted.notes = "Maple"
    await session.editItem(bat.id, from: second, to: noted)
    #expect(session.items(onList: robin.toys.id).map(\.title) == ["Doll", "Big bat"])
    #expect(session.item(id: bat.id)?.notes == "Maple")
    await until { session.isInstanceUnreachable }

    instance.conditioner.passEverything()
    let sent = instance.conditioner.requests.count
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    let patches = seen(Self.update, from: sent)
    #expect(try patches.map(fields) == [["title"], ["list_id"], ["notes"]])

    let saved = try await robin.person.signedIn().get("/items/\(bat.id)")
    #expect(saved["list_id"].string == robin.toys.id)
    #expect(saved["title"].string == "Big bat")
    #expect(saved["notes"].string == "Maple")
    try await untilInStep(session, as: robin.person)
    #expect(session.items(onList: robin.toys.id).map(\.title) == ["Doll", "Big bat"])
    #expect(session.items(onList: robin.primary.id).map(\.title) == ["Ball"])
    #expect(session.lateRefusals.isEmpty)
  }

  @Test(
    """
    A move then a delete of the item, with no connection, land in order, and the item is gone. A delete then a move \
    can't happen: the item is gone, and Move to… does nothing
    """
  )
  func deleteAndMove() async throws {
    let robin = try await person("Robin", primary: ["Ball", "Bat"], toys: ["Doll"])
    let ball = try #require(robin.items["Ball"])
    let bat = try #require(robin.items["Bat"])
    let session = try await signedIn(as: robin.person)
    instance.conditioner.dropEverything()

    await session.moveItem(bat.id, toList: robin.toys.id)
    await session.deleteItem(bat.id)
    #expect(session.item(id: bat.id) == nil)
    #expect(session.list(id: robin.toys.id)?.itemCount == 1)
    #expect(session.list(id: robin.primary.id)?.itemCount == 1)

    await session.deleteItem(ball.id)
    #expect(session.moveTargets(ofItem: ball.id) == nil)
    await session.moveItem(ball.id, toList: robin.toys.id)
    #expect(session.unsentChangeCount == 3)
    await until { session.isInstanceUnreachable }

    instance.conditioner.passEverything()
    let sent = instance.conditioner.requests.count
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    let writes = instance.conditioner.requests[sent...].filter { $0.isOn(Self.update) || $0.isOn(Self.delete) }
    #expect(writes.map { $0.isOn(Self.update) } == [true, false, false])
    #expect(try await robin.person.signedIn().status(of: "/items/\(bat.id)") == 404)
    #expect(try await robin.person.signedIn().status(of: "/items/\(ball.id)") == 404)
    #expect(session.lateRefusals.isEmpty)
    try await untilInStep(session, as: robin.person)
    #expect(session.items(onList: robin.toys.id).map(\.title) == ["Doll"])
    #expect(session.items(onList: robin.primary.id).isEmpty)
  }

  // MARK: - A lost answer

  @Test(
    """
    The answer of a move is lost, and the item is moved again before the resend. The resend has the same key and \
    list, the server moves the item once each time, and every list's positions stay whole
    """
  )
  func lostAnswer() async throws {
    let robin = try await person("Robin", primary: ["Ball", "Bat", "Cap"], toys: ["Doll"])
    let books = try await instance.builder.list("Books", of: robin.person)
    let atlas = try await instance.builder.item("Atlas", on: books, as: robin.person)
    let bat = try #require(robin.items["Bat"])
    let session = try await signedIn(as: robin.person)

    // The server moves Bat, and its answer is lost on the way back.
    let hold = instance.conditioner.hold(Self.update, at: .answer)
    await session.moveItem(bat.id, toList: robin.toys.id)
    await hold.waitUntilHeld()
    instance.conditioner.dropEverything()
    await until { session.isInstanceUnreachable }
    #expect(session.unsentChangeCount == 1)
    #expect(try await onServer(robin.toys.id, as: robin.person)[bat.id] == 1)

    // Before the resend, Bat moves on to Books.
    await session.moveItem(bat.id, toList: books.id)
    #expect(session.items(onList: books.id).map(\.title) == ["Atlas", "Bat"])
    #expect(session.items(onList: robin.toys.id).map(\.title) == ["Doll"])

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    let patches = seen(Self.update)
    let keys = patches.compactMap { $0.headers["idempotency-key"] }
    #expect(keys.count == patches.count)
    let lists = try patches.map { try JSON(parsing: $0.body)["list_id"].string }
    // The first move's key goes only with Toys, at least twice, and the second's only with Books, once.
    let firstKey = try #require(keys.first)
    #expect(zip(keys, lists).filter { $0.0 == firstKey }.allSatisfy { $0.1 == robin.toys.id })
    #expect(zip(keys, lists).filter { $0.0 == firstKey }.count >= 2)
    #expect(zip(keys, lists).filter { $0.0 != firstKey }.map(\.1) == [books.id])
    #expect(try patches.map(fields).allSatisfy { $0 == ["list_id"] })

    let primary = try await onServer(robin.primary.id, as: robin.person)
    let toys = try await onServer(robin.toys.id, as: robin.person)
    let shelf = try await onServer(books.id, as: robin.person)
    #expect(Set(primary.values) == [0, 1])
    #expect(toys == [try #require(robin.items["Doll"]).id: 0])
    #expect(shelf == [atlas.id: 0, bat.id: 1])
    try await untilInStep(session, as: robin.person)
    #expect(inCopy(robin.primary.id, of: session) == primary)
    #expect(inCopy(robin.toys.id, of: session) == toys)
    #expect(inCopy(books.id, of: session) == shelf)
    #expect(session.lateRefusals.isEmpty)
  }
}
