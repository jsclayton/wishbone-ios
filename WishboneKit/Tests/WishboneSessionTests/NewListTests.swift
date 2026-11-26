import Foundation
import GRDB
import TestSupport
import Testing
import WishboneAPI

@testable import WishboneSession

/// New list, on the Lists tab, at the session model's seam, against the real server: a list for the user or for one
/// of their children, made as an unsent change with a stand-in ID, which later changes name until the server's ID
/// takes its place. See "A new list for a child" and "Unsent changes" in `docs/spec.md`, and
/// `docs/screens/lists.md`.
@Suite("Making a new list", .timeLimit(.minutes(2)))
@MainActor
final class NewListTests {
  typealias Route = NetworkConditioner.Route

  static let createList = Route("POST", "/lists")
  static let createItem = Route("POST", "/lists/{id}/items")
  static let upload = Route("POST", "/images")

  let instance: Instance

  /// The one window of the app, as it comes to the foreground.
  let window = UUID()

  init() async throws {
    instance = try await Instance()
  }

  /// A device signed in as the person, with the copy in step with the instance. It goes through this test's
  /// conditioner, unless `apart` asks for another instance of the same server: a second device on one instance
  /// shares its session keychain.
  private func signedIn(
    as person: Fixture.Person, diagnostics: any DiagnosticsReporter = .none, apart: Bool = false
  ) async throws -> SessionModel {
    let instance = apart ? try await Instance(server: self.instance.server) : self.instance
    others.append(instance)
    let device = instance.device(diagnostics: diagnostics)
    devices.append(device)
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    try await untilInStep(session, as: person)
    return session
  }

  /// The devices that the test signed in, and their instances, kept for the whole test.
  private var devices: [Device] = []
  private var others: [Instance] = []

  /// The form of New list, with the name and the person it is for.
  private func draft(
    _ name: String, description: String = "", for recipientID: String? = nil, in session: SessionModel
  ) -> NewListDraft {
    var draft = session.newListDraft()
    draft.name = name
    draft.description = description
    if let recipientID { draft.recipientID = recipientID }
    return draft
  }

  /// The add form of a list's own Add item row, filled in by hand with the title.
  private func byHand(_ title: String, on listID: String, sourceLocation: SourceLocation = #_sourceLocation) throws
    -> ItemDraft
  {
    var state = AddScreenState(text: title, fixedTo: listID)
    let filled = state.fillItInMyself()
    let draft = try #require(filled, sourceLocation: sourceLocation)
    #expect(draft.isFilledInByHand, sourceLocation: sourceLocation)
    return draft
  }

  /// An add that ended with the item added.
  private func added(_ outcome: AddOutcome, sourceLocation: SourceLocation = #_sourceLocation) throws -> AddedItem {
    guard case .added(let item) = outcome else {
      Issue.record("The add ended with \(outcome)", sourceLocation: sourceLocation)
      throw CancellationError()
    }
    return item
  }

  /// The lists with the name that the person sees on the server.
  private func onServer(named name: String, as person: Fixture.Person) async throws -> [JSON] {
    try await person.signedIn().all("/lists").filter { $0["name"].string == name }
  }

  private var requests: [NetworkConditioner.SeenRequest] {
    instance.conditioner.requests
  }

  // MARK: - 1. In Lists at once, and its page stays

  @Test(
    """
    A new list is in Lists at once, and its page shows by its stand-in ID. The page stays when the server's ID \
    replaces it, in every change
    """
  )
  func inListsAtOnce() async throws {
    let person = try await instance.person("Robin", items: ["Ball"])
    let session = try await signedIn(as: person)
    let name = "Our house \(instance.builder.tag)"
    let history = CopyHistory(of: session)

    let id = try #require(
      await session.createList(draft("  \(name)  ", description: "For the **new** place.", in: session)))

    // At once: a stand-in ID, under the user's own lists after the primary list, in Add to, and its page.
    #expect(StandIn.isStandIn(id))
    #expect(session.listsTab.yourLists.map(\.id).last == id)
    #expect(session.listsTab.yourLists.first?.isPrimary == true)
    #expect(session.addTo.yourLists.map(\.id).contains(id))
    let page = try #require(session.listPage(id: id))
    #expect(page.list.name == name)
    #expect(page.list.description == "For the **new** place.")
    #expect(!page.list.isPrimary)
    #expect(page.isRecipient)
    #expect(page.recipients.map(\.id) == [person.id])
    #expect(page.noItems == .forEditor)
    #expect(page.list.canEdit)
    #expect(page.leave == nil)

    await until { session.unsentChangeCount == 0 }
    let serverID = try #require(session.replacedStandIns[id])
    #expect(!StandIn.isStandIn(serverID))
    history.stop()

    // The server has one list, for the user, with what the form said.
    let saved = try await onServer(named: name, as: person)
    #expect(saved.count == 1)
    #expect(saved.first?["id"].string == serverID)
    #expect(saved.first?["description"].string == "For the **new** place.")
    #expect(saved.first?["recipients"].array?.compactMap { $0["id"].string } == [person.id])

    // The page opened by the stand-in shows the list by the server's ID, and so does every lookup.
    let shown = try #require(session.listPage(id: id))
    #expect(shown.list.id == serverID)
    #expect(shown.list.name == name)
    #expect(session.list(id: id)?.id == serverID)
    // Not even for a moment did the page have nothing to show: after every change, the copy held the list by its
    // stand-in, or by the server's ID that took the stand-in's place.
    #expect(history.count > 0)
    for (lists, standIns) in zip(history.lists, history.standIns) {
      let byStandIn = lists[id] != nil
      let byServerID = standIns[id].flatMap { lists[$0] } != nil
      #expect(byStandIn != byServerID, "The copy held the list \(byStandIn ? "twice" : "under no ID")")
    }
    // A pull keeps it, by the server's ID.
    await session.syncNow()
    try await untilInStep(session, as: person)
    #expect(session.listPage(id: id)?.list.id == serverID)

    // Move to… from a sheet that the stand-in filled still takes the item there, by the server's ID.
    let ball = try #require(session.primaryListItems.first)
    await session.moveItem(ball.id, toList: id)
    #expect(session.items(onList: serverID).map(\.id) == [ball.id])
    await until { session.unsentChangeCount == 0 }
    #expect(try await person.signedIn().all("/lists/\(serverID)/items").map { $0["id"].string } == [ball.id])
  }

  // MARK: - 2. For

  @Test("For shows only with a child whose can_create_list is true, and starts on the user")
  func forChoices() async throws {
    let builder = instance.builder
    let parent = try await builder.person("Morgan")
    let child = try await builder.person("Emma", parents: [parent])
    let deactivated = try await builder.deactivate(try await builder.person("Sam", parents: [parent]))
    let loner = try await builder.person("Casey")
    let onlyDeactivated = try await builder.person("Alex")
    _ = try await builder.deactivate(try await builder.person("Jo", parents: [onlyDeactivated]))

    let session = try await signedIn(as: parent)
    // The copy holds both children in full, and the server says which can have a list made.
    #expect(session.user(id: child.id)?.record?.canCreateList == true)
    #expect(session.user(id: deactivated.id)?.record?.canCreateList == false)
    #expect(session.user?.record?.canCreateList == true)
    // For: the user first, as "You", then the child who can have a list. Never the deactivated one.
    #expect(session.newListChoices.map(\.id) == [parent.id, child.id])
    #expect(session.newListChoices.map(\.isMe) == [true, false])
    #expect(session.newListChoices.last?.user.name == child.name)
    // The form starts on the user.
    #expect(session.newListDraft().recipientID == parent.id)
    #expect(session.newListDraft().name.isEmpty)

    // No child, or only a child who can't have one: no For, and the form is for the user.
    let alone = try await signedIn(as: loner, apart: true)
    #expect(alone.newListChoices.isEmpty)
    #expect(alone.newListDraft().recipientID == loner.id)
    let withDeactivated = try await signedIn(as: onlyDeactivated, apart: true)
    #expect(withDeactivated.newListChoices.isEmpty)
    #expect(withDeactivated.newListDraft().recipientID == onlyDeactivated.id)
  }

  // MARK: - 3. A list for a child

  @Test(
    """
    A list for a child has the child as its recipient, and not the parent. It shows in the child's part, at once and \
    once the server has it. For never takes a child that it doesn't offer
    """
  )
  func forAChild() async throws {
    let builder = instance.builder
    let parent = try await builder.person("Morgan")
    let child = try await builder.person("Emma", parents: [parent])
    let deactivated = try await builder.deactivate(try await builder.person("Sam", parents: [parent]))
    let stranger = try await builder.person("Casey")
    let session = try await signedIn(as: parent)
    let name = "Cousins \(builder.tag)"

    let id = try #require(await session.createList(draft(name, for: child.id, in: session)))

    // At once: in the child's part, not under the user's own lists, with the child as its one recipient.
    let part = try #require(session.listsTab.children.first { $0.child.id == child.id })
    #expect(part.lists.map(\.id).contains(id))
    #expect(!session.listsTab.yourLists.map(\.id).contains(id))
    let page = try #require(session.listPage(id: id))
    #expect(page.recipients.map(\.id) == [child.id])
    #expect(!page.isRecipient)
    #expect(page.list.canEdit)
    // Add to offers it under the child's name, as a list of someone else's.
    let target = try #require(session.addTo.targets.first { $0.id == id })
    #expect(!target.isMine)
    #expect(target.recipientNames == [child.name])

    await until { session.unsentChangeCount == 0 }
    let serverID = try #require(session.replacedStandIns[id])
    // The server made it for the child: the child is its only recipient, and the parent edits it.
    let saved = try await parent.signedIn().get("/lists/\(serverID)")
    #expect(saved["name"].string == name)
    #expect(saved["recipients"].array?.compactMap { $0["id"].string } == [child.id])
    #expect(saved["can_edit"].bool == true)
    #expect(try await child.signedIn().get("/lists/\(serverID)")["recipients"][0]["id"].string == child.id)
    let sent = try #require(requests.last { $0.isOn(Self.createList) })
    #expect((try? JSONDecoder().decode(JSON.self, from: sent.body))?["recipient_id"].string == child.id)
    await until {
      session.listsTab.children.first { $0.child.id == child.id }?.lists.map(\.id).contains(serverID) == true
    }

    // A child whom For doesn't offer, and someone who isn't a child, get nothing, and nothing waits.
    let creates = requests.count { $0.isOn(Self.createList) }
    #expect(await session.createList(draft("Not here", for: deactivated.id, in: session)) == nil)
    #expect(await session.createList(draft("Not here", for: stranger.id, in: session)) == nil)
    #expect(session.unsentChangeCount == 0)
    #expect(try await session.database.unsentChangeCount() == 0)
    #expect(requests.count { $0.isOn(Self.createList) } == creates)
  }

  @Test("The user's own list sends no recipient_id: the server's default is the caller")
  func ownListSendsNoRecipient() async throws {
    let person = try await instance.person("Robin")
    let session = try await signedIn(as: person)
    _ = try #require(await session.createList(draft("Desk \(instance.builder.tag)", in: session)))
    await until { session.unsentChangeCount == 0 }
    let sent = try #require(requests.last { $0.isOn(Self.createList) })
    let body = try #require((try? JSONDecoder().decode(JSON.self, from: sent.body)))
    #expect(body["name"].string == "Desk \(instance.builder.tag)")
    #expect(body["recipient_id"].string == nil)
    #expect(body["description"].string == nil)
    #expect(sent.headers["idempotency-key"] != nil)
  }

  // MARK: - 4. Offline, then online

  @Test(
    """
    A list made with the network dropped, then two items added to it by hand, one of them edited, and an item moved \
    in from another list: all reach the server, in order, as one list with its three items and the edit
    """
  )
  func offlineThenOnline() async throws {
    let builder = instance.builder
    let person = try await instance.person("Robin")
    let toys = try await builder.list("Toys", of: person)
    let car = try await builder.item("Car", on: toys, as: person)
    let session = try await signedIn(as: person)
    let name = "Our house \(builder.tag)"
    instance.conditioner.dropEverything()

    let id = try #require(await session.createList(draft(name, in: session)))
    var lamp = try byHand("Lamp", on: id)
    let lampID = try added(await session.add(&lamp)).id
    var rug = try byHand("Rug", on: id)
    let rugID = try added(await session.add(&rug)).id
    #expect(StandIn.isStandIn(lampID))
    #expect(StandIn.isStandIn(rugID))
    let opened = try #require(await session.editDraft(ofItem: rugID))
    var edited = opened
    edited.notes = "Wool, 2 by 3"
    await session.editItem(rugID, from: opened, to: edited)
    await session.moveItem(car.id, toList: id)

    // At once: the list, with its three items in order, and the counts of both lists.
    #expect(session.items(onList: id).map(\.title) == ["Lamp", "Rug", "Car"])
    #expect(session.items(onList: id).map(\.position) == [0, 1, 2])
    #expect(session.list(id: id)?.itemCount == 3)
    #expect(session.list(id: toys.id)?.itemCount == 0)
    #expect(session.item(id: rugID)?.notes == "Wool, 2 by 3")
    #expect(session.unsentChangeCount == 5)
    await until { session.isInstanceUnreachable }
    #expect(try await onServer(named: name, as: person).isEmpty)

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }

    // The server has one list, with the three items in order, and the edit.
    let saved = try await onServer(named: name, as: person)
    #expect(saved.count == 1)
    let serverID = try #require(saved.first?["id"].string)
    #expect(session.replacedStandIns[id] == serverID)
    let items = try await person.signedIn().all("/lists/\(serverID)/items")
    #expect(items.map { $0["title"].string } == ["Lamp", "Rug", "Car"])
    #expect(items.first { $0["title"].string == "Rug" }?["notes"].string == "Wool, 2 by 3")
    #expect(try await person.signedIn().all("/lists/\(toys.id)/items").isEmpty)
    // The list went first, and each later change named it by the server's ID.
    let creates = requests.filter { $0.isOn(Self.createList) }
    #expect(creates.count == 1)
    let createAt = try #require(requests.firstIndex { $0.isOn(Self.createList) })
    let itemsAt = requests.indices.filter { requests[$0].isOn(Self.createItem) }
    #expect(itemsAt.count == 2)
    #expect(itemsAt.allSatisfy { $0 > createAt })
    #expect(requests.allSatisfy { !$0.target.contains(StandIn.prefix) })

    // The copy shows the server's rows, by the server's IDs, on the page that the stand-in opened.
    await until {
      session.items(onList: id).map(\.title) == ["Lamp", "Rug", "Car"]
        && session.items(onList: id).allSatisfy { !StandIn.isStandIn($0.id) }
    }
    #expect(session.listPage(id: id)?.list.id == serverID)
    #expect(session.list(id: id)?.itemCount == 3)
  }

  @Test("An add to a list whose create waits sends the list first, and adds the item by the server's ID")
  func addWhileTheCreateWaits() async throws {
    let person = try await instance.person("Robin")
    let session = try await signedIn(as: person)
    let name = "Shed \(instance.builder.tag)"
    let hold = instance.conditioner.hold(Self.createList, at: .request)

    let id = try #require(await session.createList(draft(name, in: session)))
    await hold.waitUntilHeld()
    var draft = try byHand("Rake", on: id)
    let adding = Task { await session.add(&draft) }
    hold.release()
    let item = try added(await adding.value)

    // The item went to the instance at once, on the list by the server's ID: it has no stand-in.
    #expect(!StandIn.isStandIn(item.id))
    #expect(item.listName == name)
    let serverID = try #require(try await onServer(named: name, as: person).first?["id"].string)
    #expect(try await person.signedIn().all("/lists/\(serverID)/items").map { $0["id"].string } == [item.id])
    #expect(requests.allSatisfy { !$0.target.contains(StandIn.prefix) })
    await until { session.items(onList: id).map(\.id) == [item.id] }
  }

  // MARK: - 5. An empty name

  @Test("An empty name can't be saved: nothing waits, and nothing is sent")
  func emptyName() async throws {
    let person = try await instance.person("Robin")
    let session = try await signedIn(as: person)
    let lists = session.listsTab
    for name in ["", "   ", " \n\t "] {
      let empty = draft(name, description: "Something", in: session)
      #expect(!empty.hasName)
      #expect(await session.createList(empty) == nil)
    }
    #expect(draft("A", in: session).hasName)
    #expect(session.unsentChangeCount == 0)
    #expect(try await session.database.unsentChangeCount() == 0)
    #expect(session.listsTab == lists)
    #expect(!requests.contains { $0.isOn(Self.createList) })
  }

  // MARK: - 6. A late refusal

  @Test(
    """
    A list for a child whom the admin deactivated meanwhile is refused late: it goes with every change that needs it, \
    and their uploads. The item moved to it stays where it was. The refusal shows once, and is captured by its route \
    and code
    """
  )
  func refusedLate() async throws {
    let builder = instance.builder
    let parent = try await builder.person("Morgan")
    let child = try await builder.person("Emma", parents: [parent])
    let primary = try await builder.primaryList(of: parent)
    let ball = try await builder.item("Ball", on: primary, as: parent)
    let diagnostics = RecordingDiagnostics()
    let session = try await signedIn(as: parent, diagnostics: diagnostics)
    let name = "Cousins \(builder.tag)"
    instance.conditioner.dropEverything()

    let id = try #require(await session.createList(draft(name, for: child.id, in: session)))
    var kite = try byHand("Kite", on: id)
    let photo: Photo = try #require(
      Photo(file: try PhotoAddingTests.image(width: 64, height: 48, as: .png), untitled: PhotoAddingTests.untitled))
    kite.photo = photo
    let kiteID = try added(await session.add(&kite)).id
    let opened = try #require(await session.editDraft(ofItem: kiteID))
    var edited = opened
    edited.title = "Big kite"
    await session.editItem(kiteID, from: opened, to: edited)
    await session.moveItem(ball.id, toList: id)
    await session.reorderItem(ball.id, beside: .before(kiteID))
    #expect(session.items(onList: id).map(\.title) == ["Ball", "Big kite"])
    #expect(session.items(onList: primary.id).isEmpty)
    #expect(try await session.database.unsentChangeCount() == 6)
    #expect(try await waitingFiles(in: session) == 1)
    await until { session.isInstanceUnreachable }

    // Meanwhile, the admin deactivates the child.
    _ = try await builder.deactivate(child)
    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }

    // The list is gone with everything that needed it, and the server never had any of it. Ball is where it was.
    await until { session.list(id: id) == nil }
    #expect(session.item(id: kiteID) == nil)
    await until { session.items(onList: primary.id).map(\.id) == [ball.id] }
    #expect(try await session.database.unsentChangeCount() == 0)
    #expect(try await waitingFiles(in: session) == 0)
    #expect(try await onServer(named: name, as: parent).isEmpty)
    #expect(try await parent.signedIn().all("/lists/\(primary.id)/items").map { $0["id"].string } == [ball.id])
    #expect(requests.filter { $0.isOn(Self.createList) }.count == 1)
    #expect(!requests.contains { $0.isOn(Self.createItem) || $0.isOn(Self.upload) })
    #expect(!requests.contains { $0.method == "PATCH" && $0.target.contains("/items/") })
    #expect(diagnostics.faults == [.refusedWrite(.createList, code: "user_deactivated")])

    // The next foreground shows it once: only the list's create.
    await until { session.lateRefusals.count == 1 }
    await session.cameToForeground(window: window)
    let alert = try #require(session.lateRefusalAlert)
    #expect(alert.refusals.count == 1)
    let refusal = try #require(alert.refusals.first)
    guard case .createList(let created) = refusal.action else {
      Issue.record("The refusal was of \(refusal.action)")
      return
    }
    #expect(created.id == id)
    #expect(created.recipientID == child.id)
    #expect(created.recipientName == child.name)
    #expect(refusal.title == name)
    #expect(refusal.refusal.route == .createList)
    #expect(refusal.refusal.status == 403)
    #expect(refusal.refusal.code == .userDeactivated)
    session.lateRefusalsShown(in: window)
    session.leftForeground(window: window)
    await session.cameToForeground(window: window)
    #expect(session.lateRefusalAlert == nil)
  }

  /// How many photos' bytes wait in the journal.
  private func waitingFiles(in session: SessionModel) async throws -> Int {
    try await session.database.writer.read { database in try UnsentFileRow.fetchCount(database) }
  }

  // MARK: - 7. A lost answer

  @Test("The server's answer is lost. The resend has the same key, and the server still has one list")
  func lostAnswerSendsOnce() async throws {
    let person = try await instance.person("Robin")
    let session = try await signedIn(as: person)
    let name = "Globe \(instance.builder.tag)"
    instance.conditioner.dropEverything()
    let id = try #require(await session.createList(draft(name, in: session)))
    await until { session.isInstanceUnreachable }

    // The network is back. The server makes the list, and its answer is lost on the way back.
    instance.conditioner.passEverything()
    let hold = instance.conditioner.hold(Self.createList, at: .answer)
    let sync = Task { await session.syncNow() }
    await hold.waitUntilHeld()
    instance.conditioner.dropEverything()
    _ = await sync.value
    #expect(session.unsentChangeCount == 1)
    #expect(try await onServer(named: name, as: person).count == 1)
    // The list still shows, once, by its stand-in.
    #expect(session.lists.filter { $0.name == name }.map(\.id) == [id])

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }

    let creates = requests.filter { $0.isOn(Self.createList) }
    #expect(creates.count >= 2)
    #expect(Set(creates.compactMap { $0.headers["idempotency-key"] }).count == 1)
    #expect(creates.allSatisfy { $0.headers["idempotency-key"] != nil })
    let saved = try await onServer(named: name, as: person)
    #expect(saved.count == 1)
    let serverID = try #require(saved.first?["id"].string)
    await until { session.lists.filter { $0.name == name }.map(\.id) == [serverID] }
    #expect(session.listPage(id: id)?.list.id == serverID)
  }
}
