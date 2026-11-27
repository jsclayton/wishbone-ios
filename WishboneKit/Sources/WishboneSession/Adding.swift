import Foundation
import WishboneAPI

// Adding an item: the Add screen's search, the add form's draft, and the add. See "Adding an item" in
// `docs/spec.md`, `docs/screens/add.md`, and `docs/screens/add-form.md`.
//
// A search waits for the server, by nature. So does an add that a search filled in: the form stays open while the
// instance can't be reached, and Add tries again with the same `Idempotency-Key`, so the item is added once.
//
// An add filled in by hand needs nothing that only the server can do. When the instance can't be reached, it is an
// unsent change: the item shows on its list at once, by a stand-in ID, and reaches the instance later, once. See
// "When the instance can't be reached" in `docs/spec.md`.

/// What the user gave the Add screen: a link, typed words, or a photo. The server decides what a search reads. This
/// only names the store while a link is read, and fills the form for "Fill it in myself".
public enum SearchInput: Sendable, Equatable {
  /// A web address, with its store: the host, with no `www.`.
  case link(String, store: String)

  /// Anything else, as typed.
  case words(String)

  /// A photo that the user took or chose.
  case photo(Photo)

  /// The input of the text, with no space at either end. Nil for text that is only spaces.
  public init?(_ typed: String) {
    let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if !text.contains(where: \.isWhitespace), let url = URL(string: text),
      let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
      var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty
    {
      if host.hasPrefix("www.") { host.removeFirst(4) }
      while host.hasSuffix(".") { host.removeLast() }
      self = .link(text, store: host)
    } else {
      self = .words(text)
    }
  }

  /// Whether the user gave a photo.
  public var isPhoto: Bool {
    if case .photo = self { true } else { false }
  }

  /// The text that goes to the server. Nil for a photo, which goes as a file.
  public var text: String? {
    switch self {
    case .link(let text, _), .words(let text): text
    case .photo: nil
    }
  }
}

/// What the add form holds. Nothing is saved until Add. See "What the add form holds" in `docs/spec.md`.
///
/// The form keeps the draft as its own state. It keeps the add's `Idempotency-Key`, and the images that an Add
/// already uploaded, so a second Add after a lost answer sends the same add, and the server adds the item once.
public struct ItemDraft: Sendable, Equatable {
  /// The longest title that the server takes.
  public static let titleLimit = 300

  /// The longest notes that the server takes.
  public static let notesLimit = 2000

  /// An image that the search found, to tick. The first ticked one is the primary image.
  public struct Image: Sendable, Equatable, Identifiable {
    /// The store's own address of the image. It loads with no token.
    public let url: String
    public var isTicked: Bool

    public init(url: String, isTicked: Bool) {
      self.url = url
      self.isTicked = isTicked
    }

    public var id: String { url }
  }

  /// An option that the page lists, such as a size, with the user's choice. Nil is "Not sure".
  public struct Option: Sendable, Equatable, Identifiable {
    public let name: String
    public let values: [String]
    public var choice: String?

    public init(name: String, values: [String], choice: String?) {
      self.name = name
      self.values = values
      self.choice = choice
    }

    public var id: String { name }
  }

  public var images: [Image]

  /// The photo that the user took or chose: the item's image. On Add it is uploaded before the images that the
  /// search found, so it is the primary image.
  public var photo: Photo?
  public var title: String
  public var priceMinor: Int?

  /// The top of a price range, for "Up to".
  public var topPriceMinor: Int?

  /// The price's ISO 4217 code: the page's, or USD.
  public var currency: String

  /// The store link, when the search came from a link.
  public var storeLink: SearchStoreLink?
  public var options: [Option]
  public var notes: String

  /// Whether the search cut longer typed text to the longest notes.
  public let notesWereCut: Bool

  /// Why the form is not filled in, for the note at the top of the form. See "When search can't fill in the
  /// form" in `docs/spec.md`.
  public enum Note: Sendable, Equatable {
    /// The search was over the hourly limit: the link was not read.
    case overLimit

    /// Nothing could be read from the link's store.
    case nothingFound(store: String)

    /// Nothing could be read from the photo, so the form asks for a title. This includes an instance with no model.
    case photoNotRead

    /// The add was refused with `store_blocked`, and the link was dropped from the form.
    case blocked(store: String)
  }

  /// The note at the top of the form, or nil when the search filled it in.
  public internal(set) var note: Note?

  /// The list that the item goes to, by ID: the choice in Add to. Nil is the user's primary list, where every form
  /// starts. No earlier choice is remembered: each form is new. See "Which list" in `docs/spec.md`.
  public var listID: String?

  /// Whether the form is fixed to its list: it came from a list's own Add item row, in a sheet. Add to is hidden,
  /// and the duplicate hint opens nothing.
  public private(set) var isFixedToList = false

  /// Whether the user fills the form in by hand: it has only what the user gave, from "Fill it in myself", "Add it
  /// without the link", or a search over the hourly limit, and no images that the server must download. Its Add is
  /// an unsent change when the instance can't be reached.
  public private(set) var isFilledInByHand = false

  /// The add's `Idempotency-Key`, and the item and list that it was made for. A changed item, or another list,
  /// gets a new key: the server refuses a key again with another body.
  private var key: (value: String, item: NewItem, listID: String)?

  /// The images that an earlier Add uploaded: a store's image by its address, and the photo by its ID.
  private var uploads: [String: String] = [:]

  /// The `Idempotency-Key` of the photo's upload, made at the first Add, so a second Add, or the unsent change
  /// after an Add that couldn't reach the instance, uploads the photo once.
  private var photoKey: String?

  /// The form that a search of the input filled in. A link that nothing could be read from gets the note that
  /// names its store. Typed words are never read, so they get no note. A photo is the item's image, and with no
  /// guess its title is "Photo from {date}", with the note that asks for a title.
  public init(result: SearchResult, of input: SearchInput) {
    let link = result.storeLinks.first
    images = result.imageURLs.enumerated().map { index, url in Image(url: url, isTicked: index == 0) }
    title = String((result.title ?? "").prefix(Self.titleLimit))
    priceMinor = result.priceMinor ?? link?.priceMinor
    topPriceMinor = result.topPriceMinor
    currency = result.currency ?? link?.currency ?? "USD"
    storeLink = link
    options = result.options.map { Option(name: $0.name, values: $0.values, choice: $0.selected) }
    notes = result.notes ?? ""
    notesWereCut = result.notesCut
    switch input {
    case .link(_, let store) where !result.found:
      note = .nothingFound(store: link?.store ?? store)
    case .photo(let photo):
      self.photo = photo
      if !result.found || title.allSatisfy(\.isWhitespace) {
        title = String(photo.untitled.prefix(Self.titleLimit))
        note = .photoNotRead
      }
    case .link, .words:
      break
    }
  }

  /// A blank form, from "Add it without the link".
  public init() {
    self.init(given: .words(""))
  }

  /// The form with only what the user gave, from "Fill it in myself": a link as the store link, typed words as the
  /// title, or a photo as the image, with no title. A search over the hourly limit gives it too, with its note: a
  /// photo then has the title "Photo from {date}".
  public init(given input: SearchInput, note: Note? = nil) {
    self.note = note
    isFilledInByHand = true
    images = []
    priceMinor = nil
    topPriceMinor = nil
    currency = "USD"
    options = []
    notes = ""
    notesWereCut = false
    switch input {
    case .link(let url, let store):
      title = ""
      storeLink = SearchStoreLink(url: url, store: store)
    case .words(let words):
      title = String(words.prefix(Self.titleLimit))
      storeLink = nil
    case .photo(let photo):
      self.photo = photo
      title = note == nil ? "" : String(photo.untitled.prefix(Self.titleLimit))
      storeLink = nil
    }
  }

  /// The ticked images, in order. The first is the primary image.
  public var tickedImages: [Image] {
    images.filter(\.isTicked)
  }

  /// Whether Add can go: the form has a title.
  public var hasTitle: Bool {
    !title.allSatisfy(\.isWhitespace)
  }

  /// The notes as they are saved: a line for each chosen option, such as "Size: M", then the notes. "Not sure"
  /// adds nothing. The notes are cut so that the whole fits the longest notes.
  public var savedNotes: String? {
    let lines = options.compactMap { option in option.choice.map { "\(option.name): \($0)" } }
    let typed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
    let whole = (lines + (typed.isEmpty ? [] : [typed])).joined(separator: "\n")
    guard !whole.isEmpty else { return nil }
    return String(whole.prefix(Self.notesLimit))
  }

  /// The body of the add, with the uploaded images.
  func newItem(imageIDs: [String]) -> NewItem {
    NewItem(
      title: title.trimmingCharacters(in: .whitespacesAndNewlines),
      notes: savedNotes,
      priceMinor: priceMinor,
      topPriceMinor: priceMinor == nil ? nil : topPriceMinor,
      currency: priceMinor == nil ? nil : currency,
      storeLinks: storeLink.map { link in
        [
          NewStoreLink(
            url: link.url, priceMinor: link.priceMinor, currency: link.currency,
            imageURL: link.imageURL)
        ]
      } ?? [],
      imageIDs: imageIDs)
  }

  /// The form fixed to the list, as a list's own Add item row opens it.
  public func fixed(to listID: String) -> ItemDraft {
    var draft = self
    draft.listID = listID
    draft.isFixedToList = true
    return draft
  }

  /// The key for the item on the list: the one kept, when the item and the list are the same, or a new one.
  mutating func key(for item: NewItem, onList listID: String) -> String {
    if let key, key.item == item, key.listID == listID { return key.value }
    let value = UUID().uuidString
    key = (value, item, listID)
    return value
  }

  /// The `Idempotency-Key` of the photo's upload: the one kept, or a new one.
  mutating func uploadKeyOfPhoto() -> String {
    if let photoKey { return photoKey }
    let value = UUID().uuidString
    photoKey = value
    return value
  }

  /// What `uploads` keeps the photo's upload by.
  static func uploadName(of photo: Photo) -> String {
    "photo:\(photo.id.uuidString)"
  }

  /// The ID of the image that an earlier Add uploaded from the address.
  func upload(of url: String) -> String? {
    uploads[url]
  }

  mutating func keep(upload id: String, of url: String) {
    uploads[url] = id
  }

  /// Whether the two forms hold the same typed fields. The list is not one of them: a pick in Add to is not a
  /// typed change, so Back after it asks nothing.
  public static func == (first: ItemDraft, second: ItemDraft) -> Bool {
    first.images == second.images && first.photo == second.photo && first.title == second.title
      && first.priceMinor == second.priceMinor
      && first.topPriceMinor == second.topPriceMinor && first.currency == second.currency
      && first.storeLink == second.storeLink && first.options == second.options && first.notes == second.notes
      && first.notesWereCut == second.notesWereCut && first.note == second.note
  }
}

/// How a search ended.
public enum SearchOutcome: Sendable, Equatable {
  /// The form to open: filled in, or with a note that says why it is not.
  case form(ItemDraft)

  /// The link's store is blocked on this instance (`store_blocked`). No form opens.
  case blocked(store: String)

  /// The instance can't be reached. The text stays in the field.
  case unreachable

  /// The server refused the search.
  case refused(APIError.Refusal)

  /// A fault of the app, a session that ended, or a search that was stopped.
  case failed
}

/// An item that was just added, for the "Added {title} to {list}" row.
public struct AddedItem: Sendable, Equatable {
  public let id: String
  public let title: String
  public let listName: String

  /// Whether the server couldn't save a ticked image (`image_fetch_failed`), so the item was added without it.
  public let imageWasLeftOut: Bool
}

/// How an add ended. See "After Add" in `docs/spec.md`.
public enum AddOutcome: Sendable, Equatable {
  /// The item is on the list, and in the copy.
  case added(AddedItem)

  /// The instance can't be reached. The form stays open, and Add tries again.
  case unreachable

  /// The server refused the add. For `store_blocked`, the form's link is dropped, and its note says so.
  case refused(APIError.Refusal)

  /// A fault of the app, or a session that ended.
  case failed
}

/// What the Add screen shows, apart from the field's text: the progress line while a link is read, the line for
/// an instance that can't be reached, and the "Added" row. The screen keeps it as its own state. See
/// `docs/screens/add.md`.
public struct AddScreenState: Sendable, Equatable {
  public enum Phase: Sendable, Equatable {
    /// The field, and the ways in.
    case empty

    /// A search runs: "Reading {store}…" for a link, and "Looking at your photo…" for a photo.
    case reading(SearchInput)

    /// The instance didn't answer the search: "Can't reach {address}", with Try again and Fill it in myself.
    case cantReach(SearchInput)

    /// The link's store is blocked: "Links from {store} are blocked on this Wishbone.", with Add it without the
    /// link. No form opens.
    case blocked(SearchInput, store: String)

    /// The server refused the search, with its words.
    case refused(SearchInput, APIError.Refusal)

    /// The device couldn't make a JPEG of the file that the user took or chose, so nothing was sent. The line has
    /// the words of `image_invalid`. No form opens.
    case unreadablePhoto
  }

  /// The text in the field.
  public var text: String

  public private(set) var phase = Phase.empty

  /// The item that was just added, until the user leaves the screen.
  public private(set) var added: AddedItem?

  /// The search that runs, so that a late answer of one that was stopped changes nothing.
  public private(set) var searching: UUID?

  /// The list that the screen is fixed to, in a list's sheet. Every form it gives is fixed to it. Nil on the Add
  /// screen in its place, where every form starts on the primary list.
  public let fixedListID: String?

  /// - Parameter fixedListID: The list of the Add item row that opened the screen in a sheet, or nil.
  public init(text: String = "", fixedTo fixedListID: String? = nil) {
    self.text = text
    self.fixedListID = fixedListID
  }

  /// The form, fixed to the screen's list in a sheet.
  private func fixing(_ draft: ItemDraft) -> ItemDraft {
    fixedListID.map { draft.fixed(to: $0) } ?? draft
  }

  /// A search of the field's text starts. Nil when the field is empty. The search's ID names its answer.
  public mutating func startSearch() -> (id: UUID, input: SearchInput)? {
    guard let input = SearchInput(text) else { return nil }
    return startSearch(input)
  }

  /// A search of the input starts: a photo that the user took or chose, or Try again of the one that couldn't reach
  /// the instance. The field's text stays as it is.
  public mutating func startSearch(_ input: SearchInput) -> (id: UUID, input: SearchInput) {
    let id = UUID()
    searching = id
    phase = .reading(input)
    return (id, input)
  }

  /// A search of a photo that the user took or chose starts. Nil when the device couldn't read the file as an
  /// image (`Photo(file:)` gave nil): nothing is sent, the line says why, and a search that runs is stopped.
  public mutating func startSearch(ofPhoto photo: Photo?) -> (id: UUID, input: SearchInput)? {
    guard let photo else {
      searching = nil
      phase = .unreadablePhoto
      return nil
    }
    return startSearch(.photo(photo))
  }

  /// The search's answer. The form to push, or nil. The answer of a search that was stopped changes nothing.
  public mutating func searchEnded(_ id: UUID, with outcome: SearchOutcome) -> ItemDraft? {
    guard id == searching, case .reading(let input) = phase else { return nil }
    searching = nil
    switch outcome {
    case .form(let draft):
      phase = .empty
      return fixing(draft)
    case .blocked(let store):
      phase = .blocked(input, store: store)
    case .unreachable:
      phase = .cantReach(input)
    case .refused(let refusal):
      phase = .refused(input, refusal)
    case .failed:
      phase = .empty
    }
    return nil
  }

  /// "Fill it in myself": stops the wait, and gives the form with only what the user gave. Nil when the field is
  /// empty.
  public mutating func fillItInMyself() -> ItemDraft? {
    let input: SearchInput? =
      switch phase {
      case .reading(let input), .cantReach(let input), .refused(let input, _), .blocked(let input, _): input
      case .empty, .unreadablePhoto: SearchInput(text)
      }
    searching = nil
    phase = .empty
    return input.map { fixing(ItemDraft(given: $0)) }
  }

  /// "Add it without the link", after a blocked store: a blank form.
  public mutating func addWithoutTheLink() -> ItemDraft {
    searching = nil
    phase = .empty
    return fixing(ItemDraft())
  }

  /// The field's text changed: a line about an earlier search goes.
  public mutating func textChanged() {
    if case .reading = phase { return }
    phase = .empty
  }

  /// The form added the item: the field is empty, and the "Added" row shows.
  public mutating func didAdd(_ item: AddedItem) {
    text = ""
    phase = .empty
    searching = nil
    added = item
  }

  /// The user left the Add screen: the "Added" row goes.
  public mutating func left() {
    added = nil
  }
}

extension SessionModel {
  /// Search: reads a link, or takes typed words as they are, with `POST /search`, and gives the form to open. A
  /// link is read on the server, never by the app. See "The empty Add screen" in `docs/spec.md`.
  ///
  /// When search can't fill in the form, it says why: a blocked store opens no form, and a search over the hourly
  /// limit opens the form with only what the user gave, and the note. See "When search can't fill in the form" in
  /// `docs/spec.md`.
  ///
  /// Diagnostics: never here. The client reports each error as its side asks.
  public func search(_ input: SearchInput) async -> SearchOutcome {
    guard !hasEnded else { return .failed }
    do {
      let result =
        switch input {
        case .photo(let photo): try await client.search(photo: photo.data)
        case .link(let text, _), .words(let text): try await client.search(text)
        }
      guard !hasEnded else { return .failed }
      return .form(ItemDraft(result: result, of: input))
    } catch {
      switch await writeOutcome(of: error) {
      case .unreachable: return .unreachable
      case .refused(let refusal) where refusal.code == .rateLimited:
        return .form(ItemDraft(given: input, note: .overLimit))
      case .refused(let refusal) where refusal.code == .storeBlocked:
        guard case .link(_, let store) = input else { return .refused(refusal) }
        return .blocked(store: store)
      case .refused(let refusal): return .refused(refusal)
      case .failed: return .failed
      }
    }
  }

  /// Add: uploads the photo, then each ticked image, with `POST /images`, then adds the item to the draft's list: the one picked in
  /// Add to, the one the form is fixed to, or the user's primary list. The server puts it at the end of the list.
  /// The copy has the item at once. See "Which list" and "After Add" in `docs/spec.md`.
  ///
  /// The draft keeps the add's key and the images uploaded, so a second Add after a lost answer adds the item
  /// once. An image that the server can't fetch (`image_fetch_failed`) is left out, and the item is added without
  /// it, and the added item says so. An add refused with `store_blocked` drops the link from the draft, and sets
  /// its note, so a second Add adds the item without the link.
  ///
  /// An add filled in by hand is an unsent change when the instance can't be reached: at once when the last sync
  /// found it unreachable, or when the add itself can't reach it. The item is then on its list at once, and the
  /// add ends as `added`, by the item's stand-in ID (see `addLater(_:to:)`).
  ///
  /// An add to a list that New list made, whose create waits, sends the unsent changes first, so the instance has
  /// the list. While the create still waits, an add filled in by hand is an unsent change after it, and any other
  /// add can't reach the instance.
  ///
  /// **In the share extension** nothing waits for later: it keeps no journal (ADR 0006). An add that can't reach the
  /// instance ends as `unreachable`, however the form was filled in, and Add tries again with the same key. After an
  /// add, the extension tells the app, which syncs at once. See "The share extension" in `docs/spec.md`.
  ///
  /// Diagnostics: never here. The client reports each error as its side asks.
  public func add(_ draft: inout ItemDraft) async -> AddOutcome {
    guard !hasEnded, var list = draft.listID.map({ self.list(id: $0) }) ?? primaryList else { return .failed }
    let addsLater = draft.isFilledInByHand && role.isApp
    if addsLater, isInstanceUnreachable { return await addLater(&draft, to: list) }
    if StandIn.isStandIn(list.id), role.isApp {
      // A list that New list made, whose create waits: it is sent first. The instance has no list by the stand-in.
      switch await listSendingFirst(list) {
      case .sent(let sent): list = sent
      case .waits where draft.isFilledInByHand: return await addLater(&draft, to: list)
      case .waits: return .unreachable
      case .gone: return .failed
      }
    }
    var imageWasLeftOut = false
    do {
      var imageIDs: [String] = []
      // The photo is the item's image: its bytes go up first, so it is the primary image.
      if let photo = draft.photo {
        let name = ItemDraft.uploadName(of: photo)
        if let id = draft.upload(of: name) {
          imageIDs.append(id)
        } else {
          let uploaded = try await client.uploadImage(photo.data, key: draft.uploadKeyOfPhoto())
          draft.keep(upload: uploaded.id, of: name)
          imageIDs.append(uploaded.id)
        }
      }
      for image in draft.tickedImages {
        if let id = draft.upload(of: image.url) {
          imageIDs.append(id)
          continue
        }
        do {
          let uploaded = try await client.downloadImage(image.url)
          draft.keep(upload: uploaded.id, of: image.url)
          imageIDs.append(uploaded.id)
        } catch APIError.refused(let refusal) where refusal.code == .imageFetchFailed {
          imageWasLeftOut = true
          continue
        }
      }
      let item = draft.newItem(imageIDs: imageIDs)
      let key = draft.key(for: item, onList: list.id)
      let added = try await client.createItem(item, onList: list.id, key: key)
      // The instance has the item: the app syncs, whatever happens here next.
      role.itemAdded()
      guard !hasEnded else { return .failed }
      try await database.save([added], answering: true)
      // A sync that runs now may have asked before the add. Its pull keeps the item, and one more sync asks after it.
      syncAgainIfSyncing()
      return .added(
        AddedItem(
          id: added.resource.id, title: added.resource.title, listName: list.name,
          imageWasLeftOut: imageWasLeftOut))
    } catch {
      switch await writeOutcome(of: error) {
      case .unreachable where addsLater: return await addLater(&draft, to: list)
      case .unreachable: return .unreachable
      case .refused(let refusal) where refusal.code == .storeBlocked:
        if let link = draft.storeLink {
          draft.storeLink = nil
          draft.note = .blocked(store: link.store)
        }
        return .refused(refusal)
      case .refused(let refusal): return .refused(refusal)
      case .failed: return .failed
      }
    }
  }

  /// An add filled in by hand, as an unsent change: the photo's upload, when the photo isn't uploaded yet, then the
  /// item's create, in one change of the journal. The item shows at the end of its list at once, by its stand-in ID,
  /// and a sync sends both, now or when the instance answers. See "Unsent changes" in `docs/spec.md`.
  ///
  /// Each keeps the key that the form made, and the create names the upload by the image's stand-in ID. So after an
  /// Add whose answer was lost, the instance gets the same upload and the same add again, and keeps one of each. A
  /// photo that an earlier Add uploaded is named by its ID, and isn't uploaded again.
  private func addLater(_ draft: inout ItemDraft, to list: ListRow) async -> AddOutcome {
    var changes: [LocalDatabase.NewChange] = []
    var imageIDs: [String] = []
    let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if let photo = draft.photo {
      if let id = draft.upload(of: ItemDraft.uploadName(of: photo)) {
        imageIDs.append(id)
      } else {
        let standIn = StandIn.make()
        changes.append(
          .init(.uploadImage(imageID: standIn), title: title, key: draft.uploadKeyOfPhoto(), file: photo.data))
        imageIDs.append(standIn)
      }
    }
    let item = draft.newItem(imageIDs: imageIDs)
    let created = CreatedItem(
      id: StandIn.make(), listID: list.id, item: item, storeLinks: draft.storeLink.map { [$0] } ?? [],
      addedByID: session.userID, hidesClaimState: list.recipientIDs.contains(session.userID), createdAt: .now)
    changes.append(.init(.createItem(created), title: item.title, key: draft.key(for: item, onList: list.id)))
    do {
      try await database.record(changes)
    } catch {
      Log.fault(.session, "The journal can't take an unsent change.", detail: "\(error)")
      return .failed
    }
    guard !hasEnded else { return .failed }
    await publishNow()
    Task { await syncNow() }
    return .added(AddedItem(id: created.id, title: item.title, listName: list.name, imageWasLeftOut: false))
  }

  /// What became of a list that New list made, after the changes before an add were sent.
  private enum SentList {
    /// The server has it: the list, by the server's ID.
    case sent(ListRow)

    /// Its create still waits: the instance can't be reached, or didn't decide it.
    case waits

    /// The server refused it, so the list is gone.
    case gone
  }

  /// Sends the unsent changes, the create of the list among them, and gives the list by the server's ID.
  private func listSendingFirst(_ list: ListRow) async -> SentList {
    _ = await sendUnsentChanges()
    // Read with the journal: the copy's observation may not have published the server's ID yet.
    guard let (changes, standIns) = try? await database.unsentChangesAndStandIns() else { return .waits }
    if let serverID = standIns[list.id] {
      return .sent(self.list(id: serverID) ?? list.withID(serverID))
    }
    let waits = changes.contains { change in
      if case .createList(let created) = change.action { created.id == list.id } else { false }
    }
    return waits ? .waits : .gone
  }

  private enum WriteOutcome {
    case unreachable
    case refused(APIError.Refusal)
    case failed
  }

  /// What an error of a write that waits for the server means for its screen, after the session has done what
  /// the error asks: the API's own 401 ends the session, and its 410 shows the block for an app that is too old.
  private func writeOutcome(of error: any Error) async -> WriteOutcome {
    switch error {
    case APIError.refused(let refusal):
      return .refused(refusal)
    case APIError.unreachable:
      return .unreachable
    case APIError.unauthorized:
      await endedByServer(self)
      return .failed
    case APIError.appTooOld:
      blockAppTooOld()
      return .failed
    case is APIError, is CancellationError:
      return .failed
    default:
      Log.fault(.session, "The copy can't take the added item.", detail: "\(error)")
      return .failed
    }
  }
}

extension ListRow {
  /// The list by another ID: a list that New list made, by the server's ID that took its stand-in's place, before the
  /// copy's observation publishes it.
  fileprivate func withID(_ id: String) -> ListRow {
    ListRow(
      id: id, name: name, description: description, isPrimary: isPrimary, recipientIDs: recipientIDs,
      itemCount: itemCount, createdAt: createdAt, canEdit: canEdit, canDelete: canDelete, canInvite: canInvite,
      canLeave: canLeave, version: version)
  }
}
