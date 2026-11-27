import Foundation
import Synchronization
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// The share extension, at its device's and its session model's seam, against the real server: its copy in memory
/// from the API, what it takes from the shared thing, Add and the word to the app, and its states. See "The share
/// extension" in `docs/spec.md`, and `docs/screens/share-extension.md`.
@Suite("The share extension", .timeLimit(.minutes(2)))
@MainActor
final class ShareExtensionTests {
  typealias Route = NetworkConditioner.Route

  static let me = Route("GET", "/users/me")
  static let lists = Route("GET", "/lists")
  static let versions = Route("GET", "/versions")
  static let create = Route("POST", "/lists/{id}/items")

  let instance: Instance

  /// The app group's shared container, with the install marker in it.
  let container: ScratchDirectory

  /// The marker in the container, which the app places at sign-in.
  let marker: FileInstallMarker

  /// Where the extension tells the app that it added an item.
  let app = TellingRecorder()

  init() async throws {
    instance = try await Instance()
    container = try ScratchDirectory("container")
    marker = FileInstallMarker(container: container.url)
  }

  /// The app's device, signed in as the person, with its first sync over. It puts the session in the session
  /// keychain, and the marker in the container.
  @discardableResult
  private func appSignedIn(as person: Fixture.Person, storage: SessionStorage = .memory) async throws -> SessionModel {
    let device = instance.device(storage: storage, marker: marker)
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    try await untilInStep(session, as: person)
    return session
  }

  /// The extension's device, as its entry point builds it, with the app's session keychain.
  private func shareDevice(marker: (any InstallMarker)?? = .none) -> ShareDevice {
    let given: (any InstallMarker)? =
      switch marker {
      case .none: self.marker
      case .some(let marker): marker
      }
    return ShareDevice(
      .init(
        userAgent: UserAgent(version: "1.0", isPad: false), keychain: instance.keychain, marker: given,
        tellsTheApp: app))
  }

  /// The extension's device, with the lists read.
  private func loaded() async throws -> (ShareDevice, SessionModel) {
    let share = shareDevice()
    await share.load()
    #expect(share.state == .ready)
    return (share, try #require(share.session))
  }

  /// What the container holds: the marker, and nothing else that the extension wrote.
  private var containerFiles: [String] {
    get throws {
      try FileManager.default.contentsOfDirectory(atPath: container.url.path(percentEncoded: false)).sorted()
    }
  }

  /// The search of the shared thing, as the extension starts it and takes its answer.
  private func search(_ thing: SharedThing, in session: SessionModel, state: inout AddScreenState) async throws
    -> ItemDraft?
  {
    let input = try #require(SearchInput(shared: thing))
    let started = state.startSearch(input)
    return state.searchEnded(started.id, with: await session.search(started.input))
  }

  /// An add that ended with the item added.
  private func added(_ outcome: AddOutcome, sourceLocation: SourceLocation = #_sourceLocation) throws -> AddedItem {
    guard case .added(let item) = outcome else {
      Issue.record("The add ended with \(outcome)", sourceLocation: sourceLocation)
      throw CancellationError()
    }
    return item
  }

  private func titles(on list: String, as person: Fixture.Person) async throws -> [String] {
    try await person.signedIn().all("/lists/\(list)/items").compactMap { $0["title"].string }
  }

  // MARK: - The copy in memory

  @Test("From the shared Keychain item, the extension has the user and the lists they can edit, and writes nothing")
  func readsTheUserAndTheirLists() async throws {
    let family = try await instance.builder.standardFamily()
    let books = try await instance.builder.list("Books", of: family.child)
    _ = try await instance.builder.item("Kite", on: books, as: family.child)
    let appSession = try await appSignedIn(as: family.parent)
    let before = instance.conditioner.requests.count

    let (_, session) = try await loaded()

    // The user, and Add to as the app has it: the parent's own lists, and a part for each child.
    #expect(session.user?.id == family.parent.id)
    #expect(session.primaryList?.id == appSession.primaryList?.id)
    #expect(session.addTo == appSession.addTo)
    #expect(session.addTo.children.first?.child.id == family.child.id)
    #expect(session.addTo.children.first?.targets.contains { $0.id == books.id } == true)
    // The items of the lists, for the duplicate hint, once the second read is in.
    await until { session.items(onList: books.id).map(\.title) == ["Kite"] }

    // It read the user, the lists and the children, and the items of the lists, and nothing else: no versions,
    // no gift, no occasion, no group.
    let asked = instance.conditioner.requests.dropFirst(before).map(\.target)
    #expect(asked.allSatisfy { $0.contains("/users/") || $0.contains("/lists") })
    #expect(session.gifts.isEmpty && session.occasions.isEmpty && session.groups.isEmpty)

    // It never syncs, and keeps no unsent change.
    #expect(await session.syncNow() == .stopped)
    #expect(!instance.conditioner.requests.dropFirst(before).contains { $0.isOn(Self.versions) })
    #expect(session.unsentChangeCount == 0)
    // The shared container holds only the app's marker.
    #expect(try containerFiles == [FileInstallMarker.fileName])
  }

  // MARK: - What it takes

  @Test("A link is a link. A text with links uses the first web link. A text with none is typed words")
  func whatItTakes() throws {
    let link = try #require(URL(string: "https://www.example.com/kite?color=red"))
    #expect(SearchInput(shared: .link(link)) == .link("https://www.example.com/kite?color=red", store: "example.com"))
    #expect(
      SearchInput(shared: .text("Check out this toy! https://shop.example/toy/1 and https://other.example/2"))
        == .link("https://shop.example/toy/1", store: "shop.example"))
    #expect(
      SearchInput(shared: .text("Mail me@example.com, then see http://shop.example/a."))
        == .link("http://shop.example/a", store: "shop.example"))
    #expect(SearchInput(shared: .text("  A red kite  ")) == .words("A red kite"))
    // What Wishbone can't use: a link that is no web address, and a text with nothing in it.
    #expect(SearchInput(shared: .link(try #require(URL(string: "mailto:me@example.com")))) == nil)
    #expect(SearchInput(shared: .link(try #require(URL(string: "file:///tmp/kite.txt")))) == nil)
    #expect(SearchInput(shared: .text(" \n ")) == nil)
  }

  @Test("A shared link gives the form with what the page has, and its duplicate hint is text")
  func linkGivesTheForm() async throws {
    let page = try await StorePage(title: "Kite \(instance.builder.tag)", priceMinor: 2499, images: 1)
    let robin = try await instance.person(items: [page.title])
    try await appSignedIn(as: robin)
    let (_, session) = try await loaded()
    var state = AddScreenState()

    let draft = try #require(
      await search(.text("Look! \(page.url.absoluteString) is on sale"), in: session, state: &state))

    #expect(draft.title == page.title)
    #expect(draft.storeLink?.url.contains(page.url.path()) == true)
    #expect(draft.priceMinor == 2499)
    #expect(page.reads == 1)
    // The hint names the item with the same title, and opens nothing: the extension shows no item.
    await until { session.duplicateHint(for: draft) != nil }
    let hint = try #require(session.duplicateHint(for: draft))
    #expect(hint.title == page.title)
    #expect(!hint.opensItem)
  }

  // MARK: - Add

  @Test("Add puts the item on the list picked, and tells the app once")
  func addTellsTheApp() async throws {
    let family = try await instance.builder.standardFamily()
    try await appSignedIn(as: family.parent)
    let (_, session) = try await loaded()
    var state = AddScreenState()
    let title = instance.builder.name("Puzzle")

    var draft = try #require(await search(.text(title), in: session, state: &state))
    let target = try #require(session.addTo.children.first?.targets.first)
    draft.listID = target.id
    #expect(app.count == 0)
    let item = try added(await session.add(&draft))

    #expect(item.listName == target.list.name)
    #expect(try await titles(on: target.id, as: family.parent).contains(title))
    #expect(app.count == 1)
    // Nothing waits in a journal, and the shared container holds only the app's marker.
    #expect(session.unsentChangeCount == 0)
    #expect(try containerFiles == [FileInstallMarker.fileName])
  }

  @Test("A lost answer to Add, and Add again, make one item, with the extension's own key")
  func lostAnswerAddsOnce() async throws {
    let robin = try await instance.person()
    let appSession = try await appSignedIn(as: robin)
    let (_, session) = try await loaded()
    var state = AddScreenState()
    let title = instance.builder.name("Globe")
    let draft = try #require(await search(.text(title), in: session, state: &state))

    // The server adds the item, and the answer is lost on its way back.
    let hold = instance.conditioner.hold(Self.create, at: .answer)
    let first = Task {
      var draft = draft
      return (await session.add(&draft), draft)
    }
    await hold.waitUntilHeld()
    instance.conditioner.dropEverything()
    let (outcome, kept) = await first.value
    #expect(outcome == .unreachable)
    #expect(app.count == 0)

    instance.conditioner.passEverything()
    var again = kept
    _ = try added(await session.add(&again))

    let list = try #require(appSession.primaryList)
    #expect(try await titles(on: list.id, as: robin).filter { $0 == title }.count == 1)
    let creates = instance.conditioner.requests.filter { $0.isOn(Self.create) }
    #expect(creates.count == 2)
    #expect(Set(creates.compactMap { $0.headers["idempotency-key"] }).count == 1)
    #expect(app.count == 1)
  }

  // MARK: - Its states

  @Test("With the network dropped: Can't reach, an add filled in by hand isn't kept, and Cancel keeps nothing")
  func cantReach() async throws {
    let robin = try await instance.person()
    let appSession = try await appSignedIn(as: robin)
    let kept = instance.keychain.read()
    instance.conditioner.dropEverything()

    let share = shareDevice()
    await share.load()
    #expect(share.state == .cantReach(try instance.address))

    // Try again with the network back reads the lists.
    instance.conditioner.passEverything()
    await share.load()
    #expect(share.state == .ready)
    let session = try #require(share.session)

    // The search, and an add filled in by hand, can't reach the instance: the add is not kept for later.
    instance.conditioner.dropEverything()
    #expect(await session.search(.words("Kite")) == .unreachable)
    var state = AddScreenState(text: "A kite")
    let filled = state.fillItInMyself()
    var draft = try #require(filled)
    #expect(await session.add(&draft) == .unreachable)
    #expect(session.unsentChangeCount == 0)
    #expect(session.items(onList: try #require(appSession.primaryList).id).isEmpty)

    // Cancel: the session model ends, and nothing is sent later. The session itself stays.
    await share.end()
    #expect(share.session == nil)
    instance.conditioner.passEverything()
    #expect(try await titles(on: try #require(appSession.primaryList).id, as: robin).isEmpty)
    #expect(instance.keychain.read() == kept)
    #expect(app.count == 0)
    #expect(try containerFiles == [FileInstallMarker.fileName])
  }

  @Test("The API's own 401 deletes only the Keychain item, and gives the signed-out state")
  func signedOutByServer() async throws {
    let robin = try await instance.person()
    let folder = try ScratchDirectory("app")
    try await appSignedIn(as: robin, storage: .folder(folder.url))
    let sessions = folder.url.appending(path: "Sessions").path(percentEncoded: false)
    #expect(FileManager.default.fileExists(atPath: sessions))
    let (share, session) = try await loaded()

    // Another session revokes this device's: the next request gets the API's own 401.
    try await revokeDevice(of: robin)
    var state = AddScreenState(text: "A kite")
    let filled = state.fillItInMyself()
    var draft = try #require(filled)
    #expect(await session.add(&draft) == .failed)

    #expect(share.state == .signedOut)
    #expect(share.session == nil)
    #expect(instance.keychain.read() == nil)
    // Nothing else goes: the marker and the app's database stay, for the app to clear when it next runs.
    #expect(marker.isPresent)
    #expect(FileManager.default.fileExists(atPath: sessions))
    #expect(app.count == 0)
  }

  @Test("The API's own 401 while the lists are read gives the signed-out state")
  func signedOutWhileReading() async throws {
    let robin = try await instance.person()
    try await appSignedIn(as: robin)
    try await revokeDevice(of: robin)

    let share = shareDevice()
    #expect(share.state == .loading)
    await share.load()

    #expect(share.state == .signedOut)
    #expect(instance.keychain.read() == nil)
    #expect(marker.isPresent)
  }

  @Test("A 410 gives Open Wishbone, and the session stays")
  func appTooOld() async throws {
    let robin = try await instance.person()
    try await appSignedIn(as: robin)
    let kept = instance.keychain.read()
    instance.conditioner.answer(Self.me, with: try .problem(410, code: "api_version_removed"))

    let share = shareDevice()
    await share.load()

    #expect(share.state == .appTooOld)
    #expect(instance.keychain.read() == kept)
  }

  @Test("No marker gives the signed-out state, and a missing container too. Neither forgets anything or asks anything")
  func noMarker() async throws {
    let robin = try await instance.person()
    try await appSignedIn(as: robin)
    let kept = try #require(instance.keychain.read())
    let before = instance.conditioner.requests.count

    // A reinstall, before the app was opened: the container is new, with no marker.
    let reinstalled = shareDevice(marker: .some(InMemoryInstallMarker()))
    await reinstalled.load()
    #expect(reinstalled.state == .signedOut)
    #expect(reinstalled.session == nil)

    // The container is missing: the extension can't tell.
    let missing = shareDevice(marker: .some(nil))
    await missing.load()
    #expect(missing.state == .signedOut)

    #expect(instance.keychain.read() == kept)
    #expect(instance.conditioner.requests.count == before)
  }

  @Test("With no session, the signed-out state")
  func noSession() async throws {
    let share = shareDevice()
    await share.load()
    #expect(share.state == .signedOut)
  }

  // MARK: - The app

  @Test("In the app, each word from the extension starts a sync")
  func appSyncsOnTheWord() async throws {
    let robin = try await instance.person()
    let adds = AddsRecorder()
    let device = instance.device(addsFromShareExtension: adds)
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    let session = try #require(device.session)
    try await untilInStep(session, as: robin)
    let pulls = { self.instance.conditioner.requests.filter { $0.isOn(Self.versions) }.count }
    let before = pulls()

    // The extension adds an item, and says so.
    let list = try await instance.builder.primaryList(of: robin)
    _ = try await instance.builder.item("Kite", on: list, as: robin)
    adds.yield()

    await until { session.primaryListItems.map(\.title) == ["Kite"] }
    #expect(pulls() == before + 1)
  }

  /// Revokes the device's session from the person's other session, as their Devices list in a browser does.
  private func revokeDevice(of person: Fixture.Person) async throws {
    let other = try person.signedIn()
    let sessions = try await other.all("/users/me/sessions")
    let device = try #require(
      sessions.first { $0["is_current"].bool == false && $0["user_agent"].string?.hasPrefix("Wishbone iOS/") == true })
    let id = try #require(device["id"].string)
    _ = try await other.send("DELETE", "/users/me/sessions/\(id)").expecting(204)
  }
}

/// Counts what the extension tells the app.
final class TellingRecorder: TellsTheApp {
  private let told = Mutex(0)

  var count: Int { told.withLock { $0 } }

  func itemAdded() {
    told.withLock { $0 += 1 }
  }
}

/// The word from the share extension, as the app hears it, when the test says.
final class AddsRecorder: AddsFromShareExtension {
  private let continuations = Mutex<[AsyncStream<Void>.Continuation]>([])

  func adds() -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    continuations.withLock { $0.append(continuation) }
    return stream
  }

  func yield() {
    for continuation in continuations.withLock({ $0 }) { continuation.yield() }
  }
}
