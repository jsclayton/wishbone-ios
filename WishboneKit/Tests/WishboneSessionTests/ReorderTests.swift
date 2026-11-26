import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// Reorder, at the session model's seam, against the real server. A reorder is an unsent change: the item shows at
/// its new place at once, in every window, the other items shift, and it reaches the server as `PATCH /items/{id}`
/// with only `position`. The copy takes the server's answer with its shift rule, and a refusal puts the item back.
/// See "Where an item can land", "Every drag has a way without dragging" and "What the windows show after a drop" in
/// `docs/spec.md`, and Reorder in `docs/screens/list.md`.
///
/// Each test that sends more than one change holds the pull after the send, and holds the copy to a fresh read of
/// the server then: the places that the answers and the shift rule left must be the server's, whole, from 0.
@Suite("Reordering a list", .timeLimit(.minutes(2)))
@MainActor
final class ReorderTests {
  typealias Route = NetworkConditioner.Route

  static let update = Route("PATCH", "/items/{id}")
  static let delete = Route("DELETE", "/items/{id}")
  static let create = Route("POST", "/lists/{id}/items")
  static let versions = Route("GET", "/versions")

  let instance: Instance

  /// The one window of the app, as it comes to the foreground.
  let window = UUID()

  init() async throws {
    instance = try await Instance()
  }

  /// A device signed in as the person, through this test's conditioner, with the copy in step with the instance.
  private func signedIn(as person: Fixture.Person, diagnostics: any DiagnosticsReporter = .none) async throws
    -> SessionModel
  {
    let device = instance.device(diagnostics: diagnostics)
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    try await untilInStep(session, as: person)
    return session
  }

  /// A person with their primary list and a second list, "Toys", each with the items given, in order.
  private func person(_ name: String, primary: [String], toys: [String] = []) async throws -> (
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

  /// The titles of the list's items, in the list's order, as the server has them for the person.
  private func onServer(_ listID: String, as person: Fixture.Person) async throws -> [String] {
    try await person.signedIn().all("/lists/\(listID)/items").compactMap { $0["title"].string }
  }

  /// The titles of the list's items, in the list's order, as the copy shows them.
  private func inCopy(_ listID: String, of session: SessionModel) -> [String] {
    session.items(onList: listID).map(\.title)
  }

  /// The list's items as the server has them for the person and as the copy has them agree: the same items, at the
  /// same places, whole from 0, and the list counts them as the server does. For a person who doesn't see every item,
  /// such as a parent who isn't a recipient, the places have gaps: `isWhole` is false.
  private func expectAgrees(
    _ listIDs: [String], of session: SessionModel, as person: Fixture.Person, isWhole: Bool = true,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    for listID in listIDs {
      let rows = try await person.signedIn().all("/lists/\(listID)/items")
      let server = rows.map { "\($0["id"].string ?? "")@\($0["position"].number.map { Int($0) } ?? -1)" }
      let whole = rows.indices.map { "\(rows[$0]["id"].string ?? "")@\($0)" }
      #expect(!isWhole || server == whole, "The server's places are whole from 0", sourceLocation: sourceLocation)
      let copy = session.items(onList: listID).map { "\($0.id)@\($0.position)" }
      #expect(copy == server, "The copy has the server's places", sourceLocation: sourceLocation)
      let count = try await person.signedIn().get("/lists/\(listID)")["item_count"].number.map { Int($0) }
      #expect(session.list(id: listID)?.itemCount == count, sourceLocation: sourceLocation)
    }
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

  /// The place that a request's body sends.
  private func position(of request: NetworkConditioner.SeenRequest) throws -> Int? {
    try JSON(parsing: request.body)["position"].number.map { Int($0) }
  }

  /// The ID of the item with the title on the list, as the copy shows it.
  private func id(of title: String, on listID: String, in session: SessionModel) throws -> String {
    try #require(session.items(onList: listID).first { $0.title == title }).id
  }

  // MARK: - At once, with only position

  @Test(
    """
    A reorder puts the item at its place at once, and the others shift. The request has only position, a key, and \
    no If-Match, and the server has the same order
    """
  )
  func atOnce() async throws {
    let robin = try await person("Robin", primary: ["Ball", "Bat", "Cap", "Drum"])
    let drum = try #require(robin.items["Drum"])
    let session = try await signedIn(as: robin.person)

    // Held at the request, so what shows at once can't be the server's answer.
    let hold = instance.conditioner.hold(Self.update, at: .request)
    await session.reorderItem(drum.id, beside: .before(try #require(robin.items["Ball"]).id))
    #expect(inCopy(robin.primary.id, of: session) == ["Drum", "Ball", "Bat", "Cap"])
    #expect(session.items(onList: robin.primary.id).map(\.position) == [0, 1, 2, 3])
    #expect(
      session.listPage(id: robin.primary.id)?.items(sortedBy: .listOrder).map(\.row.title) == [
        "Drum", "Ball", "Bat", "Cap",
      ])
    #expect(session.list(id: robin.primary.id)?.itemCount == 4)
    #expect(session.unsentChangeCount == 1)

    await hold.waitUntilHeld()
    hold.release()
    await until { session.unsentChangeCount == 0 }
    let patches = seen(Self.update)
    #expect(patches.count == 1)
    let patch = try #require(patches.first)
    #expect(patch.target.hasSuffix("/items/\(drum.id)"))
    #expect(try fields(of: patch) == ["position"])
    #expect(try position(of: patch) == 0)
    #expect(patch.headers["idempotency-key"] != nil)
    #expect(patch.headers["if-match"] == nil)
    #expect(try await onServer(robin.primary.id, as: robin.person) == ["Drum", "Ball", "Bat", "Cap"])
    try await untilInStep(session, as: robin.person)
    #expect(inCopy(robin.primary.id, of: session) == ["Drum", "Ball", "Bat", "Cap"])
    #expect(session.lateRefusals.isEmpty)
  }

  @Test("After the server accepts a reorder down the list, and before the pull, the copy and the server agree")
  func agreesWithAPull() async throws {
    let robin = try await person("Robin", primary: ["Ball", "Bat", "Cap", "Drum"])
    let session = try await signedIn(as: robin.person)
    let bat = try id(of: "Bat", on: robin.primary.id, in: session)

    // The pull after the reorder waits, so the copy shows what the answer and the shift rule left.
    let pull = instance.conditioner.hold(Self.versions, at: .request)
    // Bat goes after Drum, the last.
    await session.reorderItem(bat, beside: .after(try id(of: "Drum", on: robin.primary.id, in: session)))
    #expect(inCopy(robin.primary.id, of: session) == ["Ball", "Cap", "Drum", "Bat"])
    await pull.waitUntilHeld()
    await until { session.unsentChangeCount == 0 }
    #expect(try position(of: try #require(seen(Self.update).first)) == 3)
    try await expectAgrees([robin.primary.id], of: session, as: robin.person)
    #expect(try await onServer(robin.primary.id, as: robin.person) == ["Ball", "Cap", "Drum", "Bat"])

    pull.release()
    try await untilInStep(session, as: robin.person)
    try await expectAgrees([robin.primary.id], of: session, as: robin.person)
  }

  // MARK: - Where it is offered

  @Test(
    """
    Reorder is offered only in List order, and only on a list the user can edit: a giver's reorder, and one that \
    leaves the item where it is, do nothing
    """
  )
  func offered() async throws {
    let builder = instance.builder
    let robin = try await instance.person("Robin", items: ["Ball", "Bat", "Cap"])
    let morgan = try await builder.person("Morgan")
    _ = try await builder.group("Family", users: [robin, morgan])
    let lego = try await builder.list("Lego", of: morgan)
    let brick = try await builder.item("Brick", on: lego, as: morgan)
    _ = try await builder.item("Plate", on: lego, as: morgan)
    let session = try await signedIn(as: robin)
    let primary = try #require(session.primaryList)

    let own = try #require(session.listPage(id: primary.id))
    #expect(own.offersReorder(sortedBy: .listOrder))
    #expect(!own.offersReorder(sortedBy: .price))
    #expect(!own.offersReorder(sortedBy: .newest))

    // Robin is a giver on Lego: no Reorder in any order, and a reorder does nothing.
    let theirs = try #require(session.listPage(id: lego.id))
    #expect(!theirs.list.canEdit)
    #expect(ListSort.allCases.allSatisfy { !theirs.offersReorder(sortedBy: $0) })
    await session.reorderItem(brick.id, beside: .after(try id(of: "Plate", on: lego.id, in: session)))
    #expect(session.unsentChangeCount == 0)
    #expect(inCopy(lego.id, of: session) == ["Brick", "Plate"])

    // A neighbour that leaves the item where it is, the item itself, or one on another list does nothing.
    let bat = try id(of: "Bat", on: primary.id, in: session)
    let ball = try id(of: "Ball", on: primary.id, in: session)
    let cap = try id(of: "Cap", on: primary.id, in: session)
    for neighbour: ItemNeighbour in [.after(ball), .before(cap), .after(bat), .before(brick.id), .after("0")] {
      await session.reorderItem(bat, beside: neighbour)
    }
    #expect(session.unsentChangeCount == 0)
    #expect(inCopy(primary.id, of: session) == ["Ball", "Bat", "Cap"])
  }

  // MARK: - With the network dropped

  @Test("A reorder made with the network dropped waits, shows meanwhile, and is sent when the instance answers")
  func offline() async throws {
    let robin = try await person("Robin", primary: ["Ball", "Bat", "Cap"])
    let session = try await signedIn(as: robin.person)
    let cap = try id(of: "Cap", on: robin.primary.id, in: session)
    instance.conditioner.dropEverything()

    await session.reorderItem(cap, beside: .before(try id(of: "Bat", on: robin.primary.id, in: session)))
    #expect(inCopy(robin.primary.id, of: session) == ["Ball", "Cap", "Bat"])
    await until { session.isInstanceUnreachable }
    #expect(session.unsentChangeCount == 1)
    #expect(inCopy(robin.primary.id, of: session) == ["Ball", "Cap", "Bat"])
    #expect(try await onServer(robin.primary.id, as: robin.person) == ["Ball", "Bat", "Cap"])

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    #expect(try await onServer(robin.primary.id, as: robin.person) == ["Ball", "Cap", "Bat"])
    try await untilInStep(session, as: robin.person)
    try await expectAgrees([robin.primary.id], of: session, as: robin.person)
    #expect(session.lateRefusals.isEmpty)
  }

  @Test(
    """
    Three reorders in a row, with no connection, are sent in order, each with only position, and leave the copy and \
    the server in the same order
    """
  )
  func threeInARow() async throws {
    let robin = try await person("Robin", primary: ["Ball", "Bat", "Cap", "Drum"])
    let session = try await signedIn(as: robin.person)
    let list = robin.primary.id
    instance.conditioner.dropEverything()

    // Ball to the end, Drum to the top, Bat after Cap.
    await session.reorderItem(
      try id(of: "Ball", on: list, in: session), beside: .after(try id(of: "Drum", on: list, in: session)))
    #expect(inCopy(list, of: session) == ["Bat", "Cap", "Drum", "Ball"])
    await session.reorderItem(
      try id(of: "Drum", on: list, in: session), beside: .before(try id(of: "Bat", on: list, in: session)))
    #expect(inCopy(list, of: session) == ["Drum", "Bat", "Cap", "Ball"])
    await session.reorderItem(
      try id(of: "Bat", on: list, in: session), beside: .after(try id(of: "Cap", on: list, in: session)))
    #expect(inCopy(list, of: session) == ["Drum", "Cap", "Bat", "Ball"])
    #expect(session.items(onList: list).map(\.position) == [0, 1, 2, 3])
    await until { session.isInstanceUnreachable }

    instance.conditioner.passEverything()
    let sent = instance.conditioner.requests.count
    let pull = instance.conditioner.hold(Self.versions, at: .request)
    let syncing = Task { await session.syncNow() }
    await pull.waitUntilHeld()
    await until { session.unsentChangeCount == 0 }
    let patches = seen(Self.update, from: sent)
    #expect(try patches.map(fields) == [["position"], ["position"], ["position"]])
    #expect(try patches.map(position) == [3, 0, 2])
    #expect(try await onServer(list, as: robin.person) == ["Drum", "Cap", "Bat", "Ball"])
    // Before the pull: the answers and the shift rule left the server's places.
    try await expectAgrees([list], of: session, as: robin.person)
    #expect(inCopy(list, of: session) == ["Drum", "Cap", "Bat", "Ball"])

    pull.release()
    _ = await syncing.value
    try await untilInStep(session, as: robin.person)
    try await expectAgrees([list], of: session, as: robin.person)
    #expect(session.lateRefusals.isEmpty)
  }

  // MARK: - A refusal

  @Test(
    """
    A reorder that the server refuses with forbidden puts the items back in their places, in every window, shows in \
    the window that made it, and is captured by its code
    """
  )
  func refused() async throws {
    let builder = instance.builder
    let robin = try await instance.person("Robin", items: ["Ball"])
    let morgan = try await builder.person("Morgan")
    _ = try await builder.group("Family", users: [robin, morgan])
    let lego = try await builder.list("Lego", of: morgan)
    for title in ["Brick", "Plate", "Wheel"] {
      _ = try await builder.item(title, on: lego, as: morgan)
    }
    try await builder.accept(try await builder.invite(robin, to: lego, as: morgan))
    let diagnostics = RecordingDiagnostics()
    let session = try await signedIn(as: robin, diagnostics: diagnostics)
    await session.cameToForeground(window: window)
    #expect(session.listPage(id: lego.id)?.offersReorder(sortedBy: .listOrder) == true)
    let wheel = try id(of: "Wheel", on: lego.id, in: session)

    // Robin leaves Lego in a browser. They still see it, through the group, as a giver, and the copy doesn't know.
    try await robin.signedIn().send("DELETE", "/lists/\(lego.id)/recipients/\(robin.id)").expecting(204)
    let pull = instance.conditioner.hold(Self.versions, at: .request)
    await session.reorderItem(wheel, beside: .before(try id(of: "Brick", on: lego.id, in: session)), from: window)
    #expect(inCopy(lego.id, of: session) == ["Wheel", "Brick", "Plate"])

    // Rolled back before the pull: every item is back in its place.
    await pull.waitUntilHeld()
    await until { session.unsentChangeCount == 0 }
    #expect(inCopy(lego.id, of: session) == ["Brick", "Plate", "Wheel"])
    #expect(session.items(onList: lego.id).map(\.position) == [0, 1, 2])
    pull.release()

    // The refusal shows at once, in the window that made it, and only once.
    await until { session.lateRefusalAlert != nil }
    let alert = try #require(session.lateRefusalAlert)
    #expect(alert.window == window)
    #expect(alert.refusals.map(\.title) == ["Wheel"])
    let refusal = try #require(alert.refusals.first)
    #expect(refusal.refusal.status == 403)
    #expect(refusal.action == .reorderItem(ItemReorder(itemID: wheel, position: 0)))
    #expect(diagnostics.faults == [.refusedWrite(.updateItem, code: "forbidden")])
    session.lateRefusalsShown(in: window)
    session.leftForeground(window: window)
    await session.cameToForeground(window: window)
    #expect(session.lateRefusalAlert == nil)
    #expect(try await onServer(lego.id, as: robin) == ["Brick", "Plate", "Wheel"])
  }

  @Test(
    """
    A reorder of an item that another device deleted meanwhile, a 404, puts the items back until the pull, shows \
    once, and is never captured
    """
  )
  func deletedElsewhere() async throws {
    let robin = try await person("Robin", primary: ["Ball", "Bat", "Cap"])
    let cap = try #require(robin.items["Cap"])
    let diagnostics = RecordingDiagnostics()
    let session = try await signedIn(as: robin.person, diagnostics: diagnostics)
    // Deleted in a browser: the copy doesn't know.
    try await robin.person.signedIn().send("DELETE", "/items/\(cap.id)").expecting(204)

    let pull = instance.conditioner.hold(Self.versions, at: .request)
    await session.reorderItem(cap.id, beside: .before(try #require(robin.items["Ball"]).id))
    #expect(inCopy(robin.primary.id, of: session) == ["Cap", "Ball", "Bat"])
    await pull.waitUntilHeld()
    await until { session.unsentChangeCount == 0 }
    #expect(inCopy(robin.primary.id, of: session) == ["Ball", "Bat", "Cap"])
    pull.release()
    await until { session.item(id: cap.id) == nil }
    await until { session.lateRefusals.count == 1 }
    #expect(session.lateRefusals.first?.refusal.status == 404)
    #expect(diagnostics.faults.isEmpty)
    try await untilInStep(session, as: robin.person)
    try await expectAgrees([robin.primary.id], of: session, as: robin.person)
  }

  @Test(
    """
    A reorder of an item that another device moved to another list meanwhile reorders it there, and before the pull \
    the copy and the server agree on both lists
    """
  )
  func movedElsewhere() async throws {
    let robin = try await person("Robin", primary: ["Ball", "Bat", "Cap"], toys: ["Doll", "Eel"])
    let cap = try #require(robin.items["Cap"])
    let session = try await signedIn(as: robin.person)
    // Moved to Toys in a browser: the copy doesn't know.
    _ = try await robin.person.signedIn().send("PATCH", "/items/\(cap.id)", json: ["list_id": .string(robin.toys.id)])
      .expecting(200)

    let pull = instance.conditioner.hold(Self.versions, at: .request)
    await session.reorderItem(cap.id, beside: .before(try #require(robin.items["Ball"]).id))
    await pull.waitUntilHeld()
    await until { session.unsentChangeCount == 0 }
    #expect(try await onServer(robin.toys.id, as: robin.person) == ["Cap", "Doll", "Eel"])
    #expect(try await onServer(robin.primary.id, as: robin.person) == ["Ball", "Bat"])
    try await expectAgrees([robin.primary.id, robin.toys.id], of: session, as: robin.person)
    #expect(session.lateRefusals.isEmpty)

    pull.release()
    try await untilInStep(session, as: robin.person)
    try await expectAgrees([robin.primary.id, robin.toys.id], of: session, as: robin.person)
  }

  // MARK: - With other changes

  @Test(
    """
    A delete, then a reorder on the same list, with no connection: the reorder sends the place that the server reads \
    after the delete, and the copy and the server agree before the pull
    """
  )
  func afterADelete() async throws {
    let robin = try await person("Robin", primary: ["Ball", "Bat", "Cap", "Drum"])
    let session = try await signedIn(as: robin.person)
    let list = robin.primary.id
    instance.conditioner.dropEverything()

    await session.deleteItem(try id(of: "Ball", on: list, in: session))
    // Drum goes before Bat, now the first.
    await session.reorderItem(
      try id(of: "Drum", on: list, in: session), beside: .before(try id(of: "Bat", on: list, in: session)))
    #expect(inCopy(list, of: session) == ["Drum", "Bat", "Cap"])
    #expect(session.items(onList: list).map(\.position) == [0, 1, 2])
    await until { session.isInstanceUnreachable }

    instance.conditioner.passEverything()
    let sent = instance.conditioner.requests.count
    let pull = instance.conditioner.hold(Self.versions, at: .request)
    let syncing = Task { await session.syncNow() }
    await pull.waitUntilHeld()
    await until { session.unsentChangeCount == 0 }
    #expect(seen(Self.delete, from: sent).count == 1)
    #expect(try seen(Self.update, from: sent).map(position) == [0])
    #expect(try await onServer(list, as: robin.person) == ["Drum", "Bat", "Cap"])
    try await expectAgrees([list], of: session, as: robin.person)

    pull.release()
    _ = await syncing.value
    try await untilInStep(session, as: robin.person)
    try await expectAgrees([list], of: session, as: robin.person)
  }

  @Test(
    """
    A reorder then a move of one item, and a move then a reorder of another, with no connection, land in order, \
    each with only its own field, and the copy and the server agree on both lists before the pull
    """
  )
  func reorderAndMove() async throws {
    let robin = try await person("Robin", primary: ["Ball", "Bat", "Cap"], toys: ["Doll", "Eel"])
    let session = try await signedIn(as: robin.person)
    let primary = robin.primary.id
    let toys = robin.toys.id
    instance.conditioner.dropEverything()

    // Cap to the top of its list, then to Toys.
    let cap = try id(of: "Cap", on: primary, in: session)
    await session.reorderItem(cap, beside: .before(try id(of: "Ball", on: primary, in: session)))
    await session.moveItem(cap, toList: toys)
    // Ball to Toys, then to the top of Toys.
    let ball = try id(of: "Ball", on: primary, in: session)
    await session.moveItem(ball, toList: toys)
    await session.reorderItem(ball, beside: .before(try id(of: "Doll", on: toys, in: session)))
    #expect(inCopy(primary, of: session) == ["Bat"])
    #expect(inCopy(toys, of: session) == ["Ball", "Doll", "Eel", "Cap"])
    #expect(session.items(onList: toys).map(\.position) == [0, 1, 2, 3])
    #expect(session.list(id: toys)?.itemCount == 4)
    await until { session.isInstanceUnreachable }

    instance.conditioner.passEverything()
    let sent = instance.conditioner.requests.count
    let pull = instance.conditioner.hold(Self.versions, at: .request)
    let syncing = Task { await session.syncNow() }
    await pull.waitUntilHeld()
    await until { session.unsentChangeCount == 0 }
    let patches = seen(Self.update, from: sent)
    #expect(try patches.map(fields) == [["position"], ["list_id"], ["list_id"], ["position"]])
    #expect(try await onServer(toys, as: robin.person) == ["Ball", "Doll", "Eel", "Cap"])
    #expect(try await onServer(primary, as: robin.person) == ["Bat"])
    try await expectAgrees([primary, toys], of: session, as: robin.person)

    pull.release()
    _ = await syncing.value
    try await untilInStep(session, as: robin.person)
    try await expectAgrees([primary, toys], of: session, as: robin.person)
    #expect(session.lateRefusals.isEmpty)
  }

  @Test(
    """
    An item added with no connection, then reordered to the top: the create goes first, the reorder names the \
    server's ID, and the copy and the server agree before the pull
    """
  )
  func reorderOfAStandIn() async throws {
    let robin = try await person("Robin", primary: ["Ball", "Bat"])
    let session = try await signedIn(as: robin.person)
    let list = robin.primary.id
    let title = "Kite \(instance.builder.tag)"
    instance.conditioner.dropEverything()
    var form = ItemDraft(given: .words(title))
    form.listID = list
    guard case .added(let added) = await session.add(&form) else {
      Issue.record("The add gave no item")
      return
    }
    #expect(StandIn.isStandIn(added.id))
    await session.reorderItem(added.id, beside: .before(try id(of: "Ball", on: list, in: session)))
    #expect(inCopy(list, of: session) == [title, "Ball", "Bat"])
    await until { session.isInstanceUnreachable }

    instance.conditioner.passEverything()
    let sent = instance.conditioner.requests.count
    let pull = instance.conditioner.hold(Self.versions, at: .request)
    let syncing = Task { await session.syncNow() }
    await pull.waitUntilHeld()
    await until { session.unsentChangeCount == 0 }
    let serverID = session.serverID(of: added.id)
    #expect(!StandIn.isStandIn(serverID))
    let requests = instance.conditioner.requests[sent...].filter { $0.isOn(Self.create) || $0.isOn(Self.update) }
    #expect(requests.map { $0.isOn(Self.create) } == [true, false])
    let reorder = try #require(requests.last)
    #expect(reorder.target.hasSuffix("/items/\(serverID)"))
    #expect(try fields(of: reorder) == ["position"])
    #expect(try await onServer(list, as: robin.person) == [title, "Ball", "Bat"])
    try await expectAgrees([list], of: session, as: robin.person)

    pull.release()
    _ = await syncing.value
    try await untilInStep(session, as: robin.person)
    try await expectAgrees([list], of: session, as: robin.person)
    #expect(session.lateRefusals.isEmpty)
  }

  // MARK: - A lost answer

  @Test(
    """
    The answer of a reorder is lost, and another reorder is made before the resend. The resend has the same key and \
    place, the server reorders once each time, and the copy and the server agree, whole
    """
  )
  func lostAnswer() async throws {
    let robin = try await person("Robin", primary: ["Ball", "Bat", "Cap"])
    let session = try await signedIn(as: robin.person)
    let list = robin.primary.id
    let cap = try id(of: "Cap", on: list, in: session)
    let ball = try id(of: "Ball", on: list, in: session)

    // The server reorders Cap, and its answer is lost on the way back.
    let hold = instance.conditioner.hold(Self.update, at: .answer)
    await session.reorderItem(cap, beside: .before(ball))
    await hold.waitUntilHeld()
    instance.conditioner.dropEverything()
    await until { session.isInstanceUnreachable }
    #expect(session.unsentChangeCount == 1)
    #expect(try await onServer(list, as: robin.person) == ["Cap", "Ball", "Bat"])

    // Before the resend, Ball goes to the end.
    await session.reorderItem(ball, beside: .after(try id(of: "Bat", on: list, in: session)))
    #expect(inCopy(list, of: session) == ["Cap", "Bat", "Ball"])

    instance.conditioner.passEverything()
    let pull = instance.conditioner.hold(Self.versions, at: .request)
    let syncing = Task { await session.syncNow() }
    await pull.waitUntilHeld()
    await until { session.unsentChangeCount == 0 }
    let patches = seen(Self.update)
    let keys = patches.compactMap { $0.headers["idempotency-key"] }
    #expect(keys.count == patches.count)
    let places = try patches.map(position)
    // The first reorder's key goes only with its place, at least twice, and the second's only with its own, once.
    let firstKey = try #require(keys.first)
    #expect(zip(keys, places).filter { $0.0 == firstKey }.allSatisfy { $0.1 == 0 })
    #expect(zip(keys, places).filter { $0.0 == firstKey }.count >= 2)
    #expect(zip(keys, places).filter { $0.0 != firstKey }.map(\.1) == [2])
    #expect(try patches.map(fields).allSatisfy { $0 == ["position"] })
    // Under one key, the body never changes between tries.
    #expect(Set(zip(keys, patches).filter { $0.0 == firstKey }.map(\.1.body)).count == 1)
    #expect(try await onServer(list, as: robin.person) == ["Cap", "Bat", "Ball"])
    try await expectAgrees([list], of: session, as: robin.person)

    pull.release()
    _ = await syncing.value
    try await untilInStep(session, as: robin.person)
    try await expectAgrees([list], of: session, as: robin.person)
    #expect(session.lateRefusals.isEmpty)
  }

  // MARK: - Beside an item whose place the list guesses

  /// A child's primary list, A, B, Z, where Morgan claimed Z in full, so the parent, who isn't a recipient, sees only
  /// A and B. Z is last on the server, so the server puts a created or moved-in item after it.
  private func childsList() async throws -> (
    parent: Fixture.Person, child: Fixture.Person, list: Fixture.List, session: SessionModel
  ) {
    let builder = instance.builder
    let parent = try await builder.person("Pat")
    let child = try await builder.person("Emma", parents: [parent])
    let morgan = try await builder.person("Morgan")
    _ = try await builder.group("Family", users: [child, morgan, parent])
    let list = try await builder.primaryList(of: child)
    for title in ["A", "B"] {
      _ = try await builder.item(title, on: list, as: child)
    }
    let z = try await builder.item("Z", on: list, as: child)
    _ = try await builder.claim(z, as: morgan)
    let session = try await signedIn(as: parent)
    #expect(session.list(id: list.id)?.canEdit == true)
    #expect(session.items(onList: list.id).map { "\($0.title)@\($0.position)" } == ["A@0", "B@1"])
    return (parent, child, list, session)
  }

  @Test(
    """
    A parent who isn't a recipient drags an item past the last one they see, with a hidden item last: it lands after \
    it, before the hidden one, and the copy and the server agree
    """
  )
  func pastAHiddenItem() async throws {
    let (parent, child, list, session) = try await childsList()
    await session.reorderItem(
      try id(of: "A", on: list.id, in: session), beside: .after(try id(of: "B", on: list.id, in: session)))
    #expect(inCopy(list.id, of: session) == ["B", "A"])
    await until { session.unsentChangeCount == 0 }
    #expect(try await onServer(list.id, as: child) == ["B", "A", "Z"])
    try await untilInStep(session, as: parent)
    try await expectAgrees([list.id], of: session, as: parent, isWhole: false)
  }

  @Test(
    """
    A parent adds an item with no connection, then drags another after it, on a list whose last item they don't see: \
    on the server and in the copy, the item lands after the new one
    """
  )
  func afterAnAddedItem() async throws {
    let (parent, child, list, session) = try await childsList()
    instance.conditioner.dropEverything()
    var form = ItemDraft(given: .words("Kite"))
    form.listID = list.id
    guard case .added(let added) = await session.add(&form) else {
      Issue.record("The add gave no item")
      return
    }
    await session.reorderItem(try id(of: "A", on: list.id, in: session), beside: .after(added.id))
    #expect(inCopy(list.id, of: session) == ["B", "Kite", "A"])
    await until { session.isInstanceUnreachable }

    instance.conditioner.passEverything()
    let pull = instance.conditioner.hold(Self.versions, at: .request)
    let syncing = Task { await session.syncNow() }
    await pull.waitUntilHeld()
    await until { session.unsentChangeCount == 0 }
    // The create's answer put Kite after Z. The reorder read Kite's place from it, and A went after Kite.
    #expect(try await onServer(list.id, as: child) == ["B", "Z", "Kite", "A"])
    #expect(inCopy(list.id, of: session) == ["B", "Kite", "A"])
    try await expectAgrees([list.id], of: session, as: parent, isWhole: false)

    pull.release()
    _ = await syncing.value
    try await untilInStep(session, as: parent)
    #expect(inCopy(list.id, of: session) == ["B", "Kite", "A"])
    try await expectAgrees([list.id], of: session, as: parent, isWhole: false)
    #expect(session.lateRefusals.isEmpty)
  }

  @Test(
    """
    A parent moves an item in from the child's other list with no connection, then drags another after it, on a \
    list whose last item they don't see: on the server and in the copy, the item lands after the moved one
    """
  )
  func afterAMovedItem() async throws {
    let (parent, child, list, session) = try await childsList()
    let other = try await instance.builder.list("Other", of: child)
    let kite = try await instance.builder.item("Kite", on: other, as: child)
    await session.syncNow()
    await until { session.item(id: kite.id) != nil }
    instance.conditioner.dropEverything()

    await session.moveItem(kite.id, toList: list.id)
    await session.reorderItem(try id(of: "A", on: list.id, in: session), beside: .after(kite.id))
    #expect(inCopy(list.id, of: session) == ["B", "Kite", "A"])
    await until { session.isInstanceUnreachable }

    instance.conditioner.passEverything()
    let pull = instance.conditioner.hold(Self.versions, at: .request)
    let syncing = Task { await session.syncNow() }
    await pull.waitUntilHeld()
    await until { session.unsentChangeCount == 0 }
    #expect(try await onServer(list.id, as: child) == ["B", "Z", "Kite", "A"])
    #expect(inCopy(list.id, of: session) == ["B", "Kite", "A"])
    try await expectAgrees([list.id, other.id], of: session, as: parent, isWhole: false)

    pull.release()
    _ = await syncing.value
    try await untilInStep(session, as: parent)
    #expect(inCopy(list.id, of: session) == ["B", "Kite", "A"])
    try await expectAgrees([list.id, other.id], of: session, as: parent, isWhole: false)
    #expect(session.lateRefusals.isEmpty)
  }
}
