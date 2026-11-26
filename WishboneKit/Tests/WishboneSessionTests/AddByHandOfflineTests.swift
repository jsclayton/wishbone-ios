import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// An item filled in by hand while the instance can't be reached: a create in the journal, with its stand-in ID, an
/// upload of its photo that waits, and a late refusal of either. See "When the instance can't be reached" and
/// "Unsent changes" in `docs/spec.md`, ADR 0006, and the "Can't reach" states of `docs/screens/add.md` and
/// `docs/screens/add-form.md`.
@Suite("Adding an item by hand with no connection", .timeLimit(.minutes(2)))
@MainActor
final class AddByHandOfflineTests {
  typealias Route = NetworkConditioner.Route

  static let search = Route("POST", "/search")
  static let upload = Route("POST", "/images")
  static let create = Route("POST", "/lists/{id}/items")
  static let revoke = Route("DELETE", "/users/me/sessions/current")

  let instance: Instance

  /// The one window of the app, as it comes to the foreground.
  let window = UUID()

  init() async throws {
    instance = try await Instance()
  }

  /// A device signed in as the person, with the copy in step with the instance.
  private func signedIn(
    as person: Fixture.Person, storage: SessionStorage = .memory, diagnostics: any DiagnosticsReporter = .none
  ) async throws -> (Device, SessionModel) {
    let device = instance.device(storage: storage, diagnostics: diagnostics)
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    try await untilInStep(session, as: person)
    return (device, session)
  }

  /// The Add screen with the input, as a search that can't reach the instance leaves it, and the form that "Fill it
  /// in myself" then gives.
  private func filledInByHand(
    _ input: SearchInput, in session: SessionModel, sourceLocation: SourceLocation = #_sourceLocation
  ) async throws -> ItemDraft {
    var state = AddScreenState(text: input.text ?? "")
    let started = state.startSearch(input)
    #expect(state.searchEnded(started.id, with: await session.search(input)) == nil, sourceLocation: sourceLocation)
    #expect(state.phase == .cantReach(input), sourceLocation: sourceLocation)
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

  /// The items on the list with the title, as its user reads them on the server.
  private func onServer(_ title: String, on listID: String, as person: Fixture.Person) async throws -> [JSON] {
    try await person.signedIn().all("/lists/\(listID)/items").filter { $0["title"].string == title }
  }

  /// A photo as the camera or the picker gives it.
  private func photo() throws -> Photo {
    try #require(
      Photo(
        file: try PhotoAddingTests.image(width: 64, height: 48, as: .png), untitled: PhotoAddingTests.untitled))
  }

  private var requests: [NetworkConditioner.SeenRequest] {
    instance.conditioner.requests
  }

  // MARK: - 1. On its list at once, through a relaunch, and sent once

  @Test(
    """
    An item added by hand with the network dropped is at the end of its list at once, and after a relaunch. When \
    the network is back, the server has one item
    """
  )
  func addedOffline() async throws {
    let person = try await instance.person("Robin", items: ["Ball"])
    let folder = try ScratchDirectory("device")
    let title = "A red scarf \(instance.builder.tag)"
    let standIn: String
    let listID: String
    do {
      // The device goes at the end of this scope, as the app does when it ends.
      let (_, session) = try await signedIn(as: person, storage: .folder(folder.url))
      let list = try #require(session.primaryList)
      listID = list.id
      instance.conditioner.dropEverything()
      var draft = try await filledInByHand(.words(title), in: session)
      draft.priceMinor = 1999
      draft.notes = "Wool"

      let item = try added(await session.add(&draft))
      standIn = item.id

      // At once: a stand-in ID, at the end of the list, on Home, on its page, and counted on the list.
      #expect(StandIn.isStandIn(item.id))
      #expect(item.title == title)
      #expect(item.listName == list.name)
      #expect(session.items(onList: list.id).map(\.title) == ["Ball", title])
      #expect(session.primaryListItems.last?.id == item.id)
      #expect(session.list(id: list.id)?.itemCount == 2)
      let page = try #require(session.itemPage(id: item.id))
      #expect(page.item.priceMinor == 1999)
      #expect(page.item.notes == "Wool")
      #expect(page.list.id == list.id)
      // The user's own list: no claim state, as the server hides it from a recipient. One is wanted.
      #expect(page.stillWanted == nil)
      #expect(page.wanted == .count(1))
      #expect(!page.offersClaim)
      #expect(session.unsentChangeCount == 1)
      await until { session.isInstanceUnreachable }
    }

    let relaunched = instance.device(storage: .folder(folder.url))
    let session = try #require(relaunched.session)
    // What is saved shows at once: the item, by its stand-in ID, and its count.
    #expect(session.items(onList: listID).map(\.title) == ["Ball", title])
    #expect(session.item(id: standIn)?.title == title)
    #expect(session.unsentChangeCount == 1)
    await session.syncNow()
    #expect(session.isInstanceUnreachable)
    #expect(try await onServer(title, on: listID, as: person).isEmpty)

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    let saved = try await onServer(title, on: listID, as: person)
    #expect(saved.count == 1)
    let serverID = try #require(saved.first?["id"].string)
    #expect(saved.first?["price_minor"].number == 1999)
    #expect(saved.first?["notes"].string == "Wool")
    // The server's ID took the stand-in's place, and the list shows the item once.
    await until { session.items(onList: listID).last?.id == serverID }
    #expect(session.items(onList: listID).map(\.title) == ["Ball", title])
    #expect(session.serverID(of: standIn) == serverID)
    #expect(session.item(id: standIn)?.id == serverID)
    // Sent once: one create, so later syncs send nothing.
    await session.syncNow()
    #expect(requests.count { $0.isOn(Self.create) } == 1)
    #expect(try await onServer(title, on: listID, as: person).count == 1)
  }

  @Test("After a sync found the instance unreachable, Add sends nothing at once: the item waits in the journal")
  func addedWhileKnownUnreachable() async throws {
    let person = try await instance.person("Robin")
    let (_, session) = try await signedIn(as: person)
    instance.conditioner.dropEverything()
    await session.syncNow()
    #expect(session.isInstanceUnreachable)
    var draft = try await filledInByHand(.words("Socks \(instance.builder.tag)"), in: session)
    let sent = requests.count

    let item = try added(await session.add(&draft))

    #expect(StandIn.isStandIn(item.id))
    #expect(session.item(id: item.id) != nil)
    // The add asked the instance nothing. The sync that it started tried, and couldn't reach it.
    #expect(requests[sent...].allSatisfy { !$0.isOn(Self.create) })
  }

  @Test("An add that a search filled in is never an unsent change: the form stays open, and nothing waits")
  func searchFilledStaysOpen() async throws {
    let person = try await instance.person("Robin")
    let (_, session) = try await signedIn(as: person)
    let title = "Mittens \(instance.builder.tag)"
    guard case .form(var draft) = await session.search(.words(title)) else {
      Issue.record("The search gave no form")
      return
    }
    #expect(!draft.isFilledInByHand)
    instance.conditioner.dropEverything()
    await session.syncNow()

    #expect(await session.add(&draft) == .unreachable)
    #expect(session.unsentChangeCount == 0)
    #expect(session.items(onList: try #require(session.primaryList).id).allSatisfy { $0.title != title })
  }

  // MARK: - 2. A lost answer

  @Test("The server's answer is lost. The resend has the same key, and the server still has one item")
  func lostAnswerSendsOnce() async throws {
    let person = try await instance.person("Robin")
    let (_, session) = try await signedIn(as: person)
    let list = try #require(session.primaryList)
    let title = "Globe \(instance.builder.tag)"
    instance.conditioner.dropEverything()
    var draft = try await filledInByHand(.words(title), in: session)
    let item = try added(await session.add(&draft))
    await until { session.isInstanceUnreachable }

    // The network is back. The server adds the item, and its answer is lost on the way back.
    instance.conditioner.passEverything()
    let hold = instance.conditioner.hold(Self.create, at: .answer)
    let sync = Task { await session.syncNow() }
    await hold.waitUntilHeld()
    instance.conditioner.dropEverything()
    _ = await sync.value
    #expect(session.unsentChangeCount == 1)
    #expect(try await onServer(title, on: list.id, as: person).count == 1)
    // The item still shows, once, by its stand-in.
    #expect(session.items(onList: list.id).filter { $0.title == title }.map(\.id) == [item.id])

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }

    let creates = requests.filter { $0.isOn(Self.create) }
    #expect(creates.count >= 2)
    #expect(Set(creates.compactMap { $0.headers["idempotency-key"] }).count == 1)
    #expect(creates.allSatisfy { $0.headers["idempotency-key"] != nil })
    let saved = try await onServer(title, on: list.id, as: person)
    #expect(saved.count == 1)
    let serverID = try #require(saved.first?["id"].string)
    await until { session.items(onList: list.id).filter { $0.title == title }.map(\.id) == [serverID] }
  }

  @Test("An Add whose own answer is lost waits in the journal with the form's key, and the item is added once")
  func lostAnswerOfTheAdd() async throws {
    let person = try await instance.person("Robin")
    let (_, session) = try await signedIn(as: person)
    let list = try #require(session.primaryList)
    let title = "Drum \(instance.builder.tag)"
    // Fill it in myself, while the instance still answers.
    var state = AddScreenState(text: title)
    let filled = state.fillItInMyself()
    let draft = try #require(filled)

    // The server adds the item, and the answer of the Add is lost.
    let hold = instance.conditioner.hold(Self.create, at: .answer)
    let adding = Task {
      var draft = draft
      return await session.add(&draft)
    }
    await hold.waitUntilHeld()
    instance.conditioner.dropEverything()
    let item = try added(await adding.value)
    #expect(StandIn.isStandIn(item.id))
    #expect(session.item(id: item.id)?.title == title)

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    let creates = requests.filter { $0.isOn(Self.create) }
    #expect(creates.count >= 2)
    #expect(Set(creates.compactMap { $0.headers["idempotency-key"] }).count == 1)
    #expect(try await onServer(title, on: list.id, as: person).count == 1)
    await until { session.items(onList: list.id).count { $0.title == title } == 1 }
    #expect(session.items(onList: list.id).allSatisfy { !StandIn.isStandIn($0.id) })
  }

  // MARK: - 3. An open page

  @Test("An open item's page keeps showing the item when the server's ID replaces the stand-in, in every change")
  func openPageKeepsShowing() async throws {
    let person = try await instance.person("Robin")
    let (_, session) = try await signedIn(as: person)
    let title = "Kite \(instance.builder.tag)"
    instance.conditioner.dropEverything()
    var draft = try await filledInByHand(.link("https://shop.example/kite", store: "shop.example"), in: session)
    draft.title = title
    let item = try added(await session.add(&draft))
    // A window opened the item's page by its stand-in ID, with its store link.
    let page = try #require(session.itemPage(id: item.id))
    #expect(page.item.title == title)
    #expect(page.storeLinks.map(\.url) == ["https://shop.example/kite"])
    #expect(page.storeLinks.map(\.store) == ["shop.example"])
    #expect(page.copyLink == URL(string: "https://shop.example/kite"))
    await until { session.isInstanceUnreachable }

    let history = CopyHistory(of: session)
    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    history.stop()

    let serverID = try #require(session.replacedStandIns[item.id])
    #expect(!StandIn.isStandIn(serverID))
    // The page shows the item by the server's ID, with what the server has.
    let shown = try #require(session.itemPage(id: item.id))
    #expect(shown.item.id == serverID)
    #expect(shown.item.title == title)
    #expect(shown.storeLinks.map(\.url) == ["https://shop.example/kite"])
    #expect(session.copyLink(ofItem: item.id) == URL(string: "https://shop.example/kite"))
    // Not even for a moment did the page have nothing to show: after every change, the copy held the item by its
    // stand-in, or by the server's ID that took the stand-in's place.
    #expect(history.count > 0)
    for (items, standIns) in zip(history.items, history.standIns) {
      let byStandIn = items[item.id] != nil
      let byServerID = standIns[item.id].flatMap { items[$0] } != nil
      #expect(byStandIn != byServerID, "The copy held the item \(byStandIn ? "twice" : "under no ID")")
    }
  }

  // MARK: - 4. A photo

  @Test("An item with a photo: the upload is sent first, then the item with that image. The file is gone after")
  func photoUploadFirst() async throws {
    let person = try await instance.person("Robin")
    let folder = try ScratchDirectory("device")
    let (_, session) = try await signedIn(as: person, storage: .folder(folder.url))
    let list = try #require(session.primaryList)
    let photo = try photo()
    instance.conditioner.dropEverything()
    var draft = try await filledInByHand(.photo(photo), in: session)
    #expect(draft.photo == photo)
    draft.title = "Kettle \(instance.builder.tag)"

    let item = try added(await session.add(&draft))
    // One item waits: its upload goes with it, and doesn't count on its own.
    #expect(session.unsentChangeCount == 1)
    #expect(session.item(id: item.id)?.images.isEmpty == true)
    let file = try DatabaseFile(under: folder.url)
    #expect(try file.count(of: "unsentFile") == 1)
    await until { session.isInstanceUnreachable }

    instance.conditioner.passEverything()
    let sent = requests.count
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }

    // The upload went first, with the photo's bytes and a key, then the create, which named the uploaded image.
    let seen = Array(requests[sent...])
    let upload = try #require(seen.firstIndex { $0.isOn(Self.upload) })
    let create = try #require(seen.firstIndex { $0.isOn(Self.create) })
    #expect(upload < create)
    #expect(seen[upload].body == photo.data)
    #expect(seen[upload].headers["idempotency-key"] != nil)
    let saved = try #require(try await onServer(draft.title, on: list.id, as: person).first)
    let imageID = try #require(saved["primary_image"]["id"].string)
    #expect(saved["images"].array?.count == 1)
    let body = try JSON(parsing: seen[create].body)
    #expect(body["image_ids"].array?.compactMap(\.string) == [imageID])
    #expect(body["primary_image_id"].string == imageID)
    // The file is gone, and the item shows its image.
    #expect(try file.count(of: "unsentFile") == 0)
    await until { session.item(id: item.id)?.primaryImage?.id == imageID }
  }

  @Test("A photo that the server refuses late shows once, and the item is added without it")
  func photoRefusedLate() async throws {
    let person = try await instance.person("Robin")
    let folder = try ScratchDirectory("device")
    let (_, session) = try await signedIn(as: person, storage: .folder(folder.url))
    let list = try #require(session.primaryList)
    // Bytes that the server can't read as an image stand in for a photo that it refuses.
    let photo = Photo(data: Data("not a photo".utf8), untitled: "Photo")
    instance.conditioner.dropEverything()
    var draft = try await filledInByHand(.photo(photo), in: session)
    draft.title = "Lamp \(instance.builder.tag)"
    let item = try added(await session.add(&draft))
    await until { session.isInstanceUnreachable }

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }

    let saved = try await onServer(draft.title, on: list.id, as: person)
    #expect(saved.count == 1)
    #expect(saved.first?["images"].array?.isEmpty == true)
    #expect(try DatabaseFile(under: folder.url).count(of: "unsentFile") == 0)
    await until { session.lateRefusals.count == 1 }
    let refusal = try #require(session.lateRefusals.first)
    #expect(StandIn.isStandIn(try #require(refusal.action.imageID)))
    #expect(refusal.title == draft.title)
    #expect(refusal.refusal.code == .imageInvalid)
    await until { session.item(id: item.id)?.title == draft.title }
  }

  // MARK: - 5. A late refusal

  @Test(
    """
    An add to a list that the user can no longer edit is refused late: the item goes, the refusal shows once, and \
    is captured by its route and code
    """
  )
  func refusedLate() async throws {
    let builder = instance.builder
    let robin = try await builder.person("Robin")
    let morgan = try await builder.person("Morgan")
    _ = try await builder.group("Family", users: [robin, morgan])
    let lego = try await builder.list("Lego", of: morgan)
    try await builder.accept(try await builder.invite(robin, to: lego, as: morgan))
    let diagnostics = RecordingDiagnostics()
    let (_, session) = try await signedIn(as: robin, diagnostics: diagnostics)
    #expect(session.list(id: lego.id)?.canEdit == true)
    let title = "Bricks \(builder.tag)"

    instance.conditioner.dropEverything()
    var draft = try await filledInByHand(.words(title), in: session)
    draft.listID = lego.id
    let item = try added(await session.add(&draft))
    #expect(session.items(onList: lego.id).last?.id == item.id)
    await until { session.isInstanceUnreachable }
    // Meanwhile, Robin leaves the list in a browser. They still see it, through the group, as a giver.
    try await robin.signedIn().send("DELETE", "/lists/\(lego.id)/recipients/\(robin.id)").expecting(204)

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }

    // The item is gone, and the server never had it.
    await until { session.items(onList: lego.id).allSatisfy { $0.title != title } }
    #expect(session.item(id: item.id) == nil)
    #expect(try await onServer(title, on: lego.id, as: morgan).isEmpty)
    await until { session.lateRefusals.count == 1 }
    #expect(session.lateRefusalAlert == nil)
    #expect(diagnostics.faults == [.refusedWrite(.createItem, code: "forbidden")])

    // The next foreground shows it once, with what it was.
    await session.cameToForeground(window: window)
    let alert = try #require(session.lateRefusalAlert)
    let refusal = try #require(alert.refusals.first)
    #expect(alert.refusals.count == 1)
    guard case .createItem(let created) = refusal.action else {
      Issue.record("The refusal was of \(refusal.action)")
      return
    }
    #expect(created.id == item.id)
    #expect(created.listID == lego.id)
    #expect(refusal.title == title)
    #expect(refusal.refusal.route == .createItem)
    #expect(refusal.refusal.status == 403)
    session.lateRefusalsShown(in: window)
    session.leftForeground(window: window)
    await session.cameToForeground(window: window)
    #expect(session.lateRefusalAlert == nil)
  }

  // MARK: - 6. A blocked store

  @Test("A link to a blocked store, kept as the store link: the late 422 takes the item out, with store_blocked")
  // The words of the line are the hosted `UnsentChangeWordsTests`'.
  func blockedStoreRefusedLate() async throws {
    let blocked = try await instance.builder.blockedStore("shop")
    let person = try await instance.person("Robin")
    let diagnostics = RecordingDiagnostics()
    let (_, session) = try await signedIn(as: person, diagnostics: diagnostics)
    let list = try #require(session.primaryList)
    let link = "https://\(blocked.store)/products/kite"
    let title = "Kite \(instance.builder.tag)"

    instance.conditioner.dropEverything()
    var draft = try await filledInByHand(.link(link, store: blocked.store), in: session)
    #expect(draft.storeLink == SearchStoreLink(url: link, store: blocked.store))
    draft.title = title
    let item = try added(await session.add(&draft))
    #expect(session.storeLinks(ofItem: item.id).map(\.url) == [link])
    await until { session.isInstanceUnreachable }

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }

    #expect(session.item(id: item.id) == nil)
    #expect(session.storeLinks(ofItem: item.id).isEmpty)
    #expect(try await onServer(title, on: list.id, as: person).isEmpty)
    await until { session.lateRefusals.count == 1 }
    let refusal = try #require(session.lateRefusals.first)
    #expect(refusal.refusal.code == .storeBlocked)
    #expect(refusal.refusal.status == 422)
    guard case .createItem(let created) = refusal.action else {
      Issue.record("The refusal was of \(refusal.action)")
      return
    }
    #expect(created.storeLinks.map(\.store) == [blocked.store])
    // A blocked store is never captured, on any route.
    #expect(diagnostics.faults.isEmpty, "\(diagnostics.faults)")
  }

  // MARK: - 7. Sign-out

  @Test("Sign-out discards the waiting creates and their photo files")
  func signOutDiscards() async throws {
    let person = try await instance.person("Robin")
    let folder = try ScratchDirectory("device")
    let (device, session) = try await signedIn(as: person, storage: .folder(folder.url))
    let list = try #require(session.primaryList)
    instance.conditioner.dropEverything()
    var draft = try await filledInByHand(.photo(try photo()), in: session)
    draft.title = "Vase \(instance.builder.tag)"
    _ = try added(await session.add(&draft))
    #expect(try DatabaseFile(under: folder.url).count(of: "unsentFile") == 1)
    await until { session.isInstanceUnreachable }

    // The instance answers again, but the upload can't get through.
    instance.conditioner.passEverything()
    instance.conditioner.answer(Self.upload, with: NetworkConditioner.CannedAnswer(status: 503))
    await device.signOut()

    // It tried to send, then revoked the session, and forgot the item and its photo with the database.
    let tried = try #require(requests.lastIndex { $0.isOn(Self.upload) })
    let revoked = try #require(requests.lastIndex { $0.isOn(Self.revoke) })
    #expect(tried < revoked)
    #expect(device.session == nil)
    #expect(
      !FileManager.default.fileExists(atPath: folder.url.appending(path: "Sessions").path(percentEncoded: false)))
    #expect(session.unsentChangeCount == 0)
    #expect(!requests.contains { $0.isOn(Self.create) })
    #expect(try await onServer(draft.title, on: list.id, as: person).isEmpty)
    #expect(instance.device(storage: .folder(folder.url)).session == nil)
  }

  // MARK: - 8. The count

  @Test("The \"Can't reach\" line counts the waiting creates: one for each item, with or without a photo")
  func countsTheCreates() async throws {
    let person = try await instance.person("Robin")
    let (_, session) = try await signedIn(as: person)
    instance.conditioner.dropEverything()

    var words = try await filledInByHand(.words("Scarf \(instance.builder.tag)"), in: session)
    _ = try added(await session.add(&words))
    #expect(session.unsentChangeCount == 1)
    var photo = try await filledInByHand(.photo(try photo()), in: session)
    photo.title = "Mug \(instance.builder.tag)"
    _ = try added(await session.add(&photo))

    #expect(session.unsentChangeCount == 2)
    await until { session.isInstanceUnreachable }
    #expect(session.screenState(hasRows: true) == .saved(cantReach: true))
  }
}

extension UnsentChange.Action {
  /// The stand-in ID of an upload. Nil for any other change.
  fileprivate var imageID: String? {
    if case .uploadImage(let id) = self { id } else { nil }
  }
}
