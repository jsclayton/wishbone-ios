import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// Adding an item from the Add screen, at the session model's seam, against the real server and a store page that
/// it reads: the search, the add form's draft, the add to the primary list, and the Add screen's state. See
/// "Adding an item" in `docs/spec.md`, `docs/screens/add.md`, and `docs/screens/add-form.md`.
@Suite("Adding an item", .timeLimit(.minutes(2)))
@MainActor
final class AddingTests {
  typealias Route = NetworkConditioner.Route

  static let search = Route("POST", "/search")
  static let upload = Route("POST", "/images")
  static let create = Route("POST", "/lists/{id}/items")

  let instance: Instance

  init() async throws {
    instance = try await Instance()
  }

  /// A device signed in as a new person, with the first sync over: the copy has the primary list.
  private func signedIn() async throws -> (SessionModel, Fixture.Person) {
    let person = try await instance.person("Robin")
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    try await untilInStep(session, as: person)
    #expect(session.primaryList != nil)
    return (session, person)
  }

  /// The search of the text, as the Add screen starts it and takes its answer. The form to push, or nil.
  private func search(_ text: String, in session: SessionModel, state: inout AddScreenState) async -> ItemDraft? {
    state.text = text
    guard let started = state.startSearch() else { return nil }
    let outcome = await session.search(started.input)
    return state.searchEnded(started.id, with: outcome)
  }

  /// The item on the server, as its user reads it.
  private func onServer(_ id: String, as person: Fixture.Person) async throws -> JSON {
    try await person.signedIn().get("/items/\(id)")
  }

  /// An add that ended with the item added.
  private func added(_ outcome: AddOutcome, sourceLocation: SourceLocation = #_sourceLocation) throws -> AddedItem {
    guard case .added(let item) = outcome else {
      Issue.record("The add ended with \(outcome)", sourceLocation: sourceLocation)
      throw CancellationError()
    }
    return item
  }

  @Test("A link gives a form with the title, the store link with its price, the images, and the options")
  func linkFillsTheForm() async throws {
    let page = try await StorePage(
      title: "Kite \(instance.builder.tag)", priceMinor: 2499, images: 3,
      options: [.init("Size", values: ["S", "M", "L"], selected: "M")])
    let (session, _) = try await signedIn()
    var state = AddScreenState()

    let draft = try #require(await search(page.url.absoluteString, in: session, state: &state))

    #expect(draft.title == page.title)
    let link = try #require(draft.storeLink)
    #expect(link.store == "localhost")
    #expect(link.url.contains(page.url.path()))
    #expect(link.priceMinor == 2499)
    #expect(link.currency == "USD")
    #expect(draft.priceMinor == 2499)
    #expect(draft.images.map(\.url) == page.imageURLs.map(\.absoluteString))
    // The first image is ticked, so it is the primary image unless the user changes it.
    #expect(draft.images.map(\.isTicked) == [true, false, false])
    #expect(draft.options == [.init(name: "Size", values: ["S", "M", "L"], choice: "M")])
    #expect(!draft.notesWereCut)
    // The screen is back to its field, with the text still in it, under the pushed form.
    #expect(state.phase == .empty)
    #expect(state.text == page.url.absoluteString)
    #expect(page.reads == 1)
  }

  @Test("Add puts the item on the primary list, with the ticked images, the first ticked as primary, and the link")
  func addPutsTheItemOnThePrimaryList() async throws {
    let page = try await StorePage(title: "Lantern \(instance.builder.tag)", priceMinor: 1800, images: 3)
    let (session, person) = try await signedIn()
    var state = AddScreenState()
    var draft = try #require(await search(page.url.absoluteString, in: session, state: &state))
    // The user ticks the last two images, and clears the first.
    draft.images[0].isTicked = false
    draft.images[1].isTicked = true
    draft.images[2].isTicked = true

    let item = try added(await session.add(&draft))
    state.didAdd(item)

    let list = try #require(session.primaryList)
    #expect(item.title == page.title)
    #expect(item.listName == list.name)
    // The copy has the item at once, before any sync.
    await until { session.item(id: item.id) != nil }
    let row = try #require(session.item(id: item.id))
    #expect(row.listID == list.id)
    #expect(row.images.count == 2)
    #expect(row.primaryImage == row.images.first)
    #expect(session.storeLinks(ofItem: item.id).map(\.store) == ["localhost"])
    #expect(row.priceMinor == 1800)

    // The server has it as the copy does: two images uploaded from the store's addresses, in the order ticked.
    let uploads = instance.conditioner.requests.filter { $0.isOn(Self.upload) }
    #expect(
      try uploads.map { try JSON(parsing: $0.body)["url"].string }
        == page.imageURLs.dropFirst().map(\.absoluteString))
    let saved = try await onServer(item.id, as: person)
    #expect(saved["list_id"].string == list.id)
    #expect(saved["images"].array?.count == 2)
    #expect(saved["primary_image"]["id"] == saved["images"][0]["id"])
    #expect(saved["store_links"][0]["url"].string?.contains(page.url.path()) == true)

    // After Add, the field is empty, and the "Added" row names the item and the list.
    #expect(state.text.isEmpty)
    #expect(state.added == item)
  }

  @Test("Typed words give a form with the title and no store link, and the add works")
  func typedWords() async throws {
    let (session, person) = try await signedIn()
    var state = AddScreenState()
    let words = "a book about sharks \(instance.builder.tag)"

    var draft = try #require(await search(words, in: session, state: &state))
    #expect(draft.title == words)
    #expect(draft.storeLink == nil)
    #expect(draft.images.isEmpty)
    #expect(draft.options.isEmpty)
    #expect(draft.hasTitle)

    let item = try added(await session.add(&draft))
    await until { session.item(id: item.id) != nil }
    let saved = try await onServer(item.id, as: person)
    #expect(saved["title"].string == words)
    #expect(saved["store_links"].array?.isEmpty == true)
    #expect(saved["images"].array?.isEmpty == true)
    #expect(instance.conditioner.requests.filter { $0.isOn(Self.upload) }.isEmpty)
  }

  @Test("A chosen option is saved into the notes, and Not sure adds nothing")
  func optionsGoIntoTheNotes() async throws {
    let page = try await StorePage(
      title: "Boots \(instance.builder.tag)", priceMinor: 6000, images: 1,
      options: [
        .init("Size", values: ["7", "8", "9"]), .init("Color", values: ["Red", "Blue"], selected: "Red"),
      ])
    let (session, person) = try await signedIn()
    var state = AddScreenState()
    var draft = try #require(await search(page.url.absoluteString, in: session, state: &state))
    #expect(draft.options.map(\.name) == ["Size", "Color"])
    #expect(draft.options.map(\.choice) == [nil, "Red"])

    // The user picks a size, and sets the color to "Not sure".
    draft.options[0].choice = "8"
    draft.options[1].choice = nil
    draft.notes = "For the snow"
    #expect(draft.savedNotes == "Size: 8\nFor the snow")

    let item = try added(await session.add(&draft))
    let saved = try await onServer(item.id, as: person)
    #expect(saved["notes"].string == "Size: 8\nFor the snow")

    // With every option "Not sure", and no notes of the user's own, the item has no notes.
    var unsure = draft
    unsure.options[0].choice = nil
    unsure.notes = ""
    #expect(unsure.savedNotes == nil)
  }

  @Test("Typed text over 2000 characters gives the line that the notes were cut")
  func notesWereCut() async throws {
    let (session, _) = try await signedIn()
    var state = AddScreenState()
    let typed = "socks " + String(repeating: "wool ", count: 450)
    #expect(typed.count > ItemDraft.notesLimit)

    let draft = try #require(await search(typed, in: session, state: &state))
    #expect(draft.notesWereCut)
    #expect(draft.notes.count == ItemDraft.notesLimit)
    #expect(draft.title.count <= ItemDraft.titleLimit)

    // Words that fit are not cut.
    let short = try #require(await search("socks", in: session, state: &state))
    #expect(!short.notesWereCut)
  }

  @Test("Fill it in myself, while a link is read, gives a form with only the link, and the late answer is ignored")
  func fillItInMyself() async throws {
    let page = try await StorePage(title: "Drum \(instance.builder.tag)", priceMinor: 3000)
    let (session, _) = try await signedIn()
    var state = AddScreenState(text: page.url.absoluteString)
    let hold = page.hold()

    let start = state.startSearch()
    let started = try #require(start)
    #expect(state.phase == .reading(.link(page.url.absoluteString, store: "localhost")))
    let reading = Task { await session.search(started.input) }
    await hold.waitUntilHeld()

    let filled = state.fillItInMyself()
    let draft = try #require(filled)
    #expect(draft.storeLink == SearchStoreLink(url: page.url.absoluteString, store: "localhost"))
    #expect(draft.title.isEmpty)
    #expect(!draft.hasTitle)
    #expect(draft.images.isEmpty)
    #expect(draft.priceMinor == nil)
    #expect(draft.options.isEmpty)
    #expect(state.phase == .empty)

    // The search's answer comes after, and changes nothing: no form, and the screen as it was.
    hold.release()
    let late = await reading.value
    guard case .found = late else {
      Issue.record("The held search ended with \(late)")
      return
    }
    let before = state
    #expect(state.searchEnded(started.id, with: late) == nil)
    #expect(state == before)
    #expect(state.text == page.url.absoluteString)
  }

  @Test("With the network dropped at the search, the screen can't reach, keeps the text, and Try again works")
  func cantReachTheSearch() async throws {
    let (session, _) = try await signedIn()
    var state = AddScreenState()
    let words = "a red scarf \(instance.builder.tag)"
    instance.conditioner.dropEverything()

    #expect(await search(words, in: session, state: &state) == nil)
    #expect(state.phase == .cantReach(.words(words)))
    #expect(state.text == words)

    // Fill it in myself is offered there too, with what the user gave.
    var offline = state
    let filled = offline.fillItInMyself()
    #expect(filled?.title == words)

    // Try again, with the network back, opens the form.
    instance.conditioner.passEverything()
    let draft = try #require(await search(state.text, in: session, state: &state))
    #expect(draft.title == words)
    #expect(state.phase == .empty)
  }

  @Test("With the network dropped at Add, the form stays open, and a second Add after a lost answer adds one item")
  func lostAnswerAddsOnce() async throws {
    let page = try await StorePage(title: "Globe \(instance.builder.tag)", priceMinor: 4200, images: 2)
    let (session, person) = try await signedIn()
    var state = AddScreenState()
    let draft = try #require(await search(page.url.absoluteString, in: session, state: &state))

    // The server adds the item, and the answer is lost on its way back.
    let hold = instance.conditioner.hold(Self.create, at: .answer)
    let first = Task {
      var draft = draft
      let outcome = await session.add(&draft)
      return (outcome, draft)
    }
    await hold.waitUntilHeld()
    instance.conditioner.dropEverything()
    let (outcome, kept) = await first.value
    #expect(outcome == .unreachable)
    // The form keeps what it had.
    #expect(kept == draft)

    // Add again, with the network back.
    instance.conditioner.passEverything()
    var again = kept
    let item = try added(await session.add(&again))

    // The server made one item, with the image uploaded once, and both adds carried one key.
    let list = try #require(session.primaryList)
    let items = try await person.signedIn().all("/lists/\(list.id)/items")
    #expect(items.filter { $0["title"].string == page.title }.count == 1)
    #expect(items.first { $0["title"].string == page.title }?["id"].string == item.id)
    let creates = instance.conditioner.requests.filter { $0.isOn(Self.create) }
    #expect(creates.count >= 2)
    #expect(Set(creates.compactMap { $0.headers["idempotency-key"] }).count == 1)
    #expect(instance.conditioner.requests.filter { $0.isOn(Self.upload) }.count == 1)
    await until { session.item(id: item.id) != nil }
  }

  @Test("The Added row goes when the user leaves the screen")
  func addedRowGoes() async throws {
    let (session, _) = try await signedIn()
    var state = AddScreenState()
    var draft = try #require(await search("a kazoo \(instance.builder.tag)", in: session, state: &state))
    let item = try added(await session.add(&draft))

    state.didAdd(item)
    #expect(state.added == item)
    #expect(state.text.isEmpty)

    // A change of tab, or a push of the item's page, leaves the screen.
    state.left()
    #expect(state.added == nil)
    // Coming back shows the empty screen.
    #expect(state.phase == .empty)
  }
}
