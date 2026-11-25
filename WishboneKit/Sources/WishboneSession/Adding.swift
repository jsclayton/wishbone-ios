import Foundation
import WishboneAPI

// Adding an item: the Add screen's search, the add form's draft, and the add. See "Adding an item" in
// `docs/spec.md`, `docs/screens/add.md`, and `docs/screens/add-form.md`.
//
// A search waits for the server, by nature. So does an add that a search filled in: the form stays open while the
// instance can't be reached, and Add tries again with the same `Idempotency-Key`, so the item is added once.

/// What the user gave the Add screen: a link, or typed words. The server decides what a search reads. This only
/// names the store while a link is read, and fills the form for "Fill it in myself".
public enum SearchInput: Sendable, Equatable {
  /// A web address, with its store: the host, with no `www.`.
  case link(String, store: String)

  /// Anything else, as typed.
  case words(String)

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

  /// The text that goes to the server.
  public var text: String {
    switch self {
    case .link(let text, _), .words(let text): text
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

  /// The add's `Idempotency-Key`, and the item that it was made for. A changed item gets a new key: the server
  /// refuses a key again with another body.
  private var key: (value: String, item: NewItem)?

  /// The images that an earlier Add uploaded, by their store address.
  private var uploads: [String: String] = [:]

  /// The form that a search filled in.
  public init(result: SearchResult) {
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
  }

  /// The form with only what the user gave, from "Fill it in myself": a link as the store link, or typed words as
  /// the title.
  public init(given input: SearchInput) {
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

  /// The key for the item: the one kept, when the item is the same, or a new one.
  mutating func key(for item: NewItem) -> String {
    if let key, key.item == item { return key.value }
    let value = UUID().uuidString
    key = (value, item)
    return value
  }

  /// The ID of the image that an earlier Add uploaded from the address.
  func upload(of url: String) -> String? {
    uploads[url]
  }

  mutating func keep(upload id: String, of url: String) {
    uploads[url] = id
  }

  public static func == (first: ItemDraft, second: ItemDraft) -> Bool {
    first.images == second.images && first.title == second.title && first.priceMinor == second.priceMinor
      && first.topPriceMinor == second.topPriceMinor && first.currency == second.currency
      && first.storeLink == second.storeLink && first.options == second.options && first.notes == second.notes
      && first.notesWereCut == second.notesWereCut
  }
}

/// How a search ended.
public enum SearchOutcome: Sendable, Equatable {
  /// The form to open, filled in.
  case found(ItemDraft)

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
}

/// How an add ended. See "After Add" in `docs/spec.md`.
public enum AddOutcome: Sendable, Equatable {
  /// The item is on the list, and in the copy.
  case added(AddedItem)

  /// The instance can't be reached. The form stays open, and Add tries again.
  case unreachable

  /// The server refused the add.
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

    /// A search runs: "Reading {store}…" for a link.
    case reading(SearchInput)

    /// The instance didn't answer the search: "Can't reach {address}", with Try again and Fill it in myself.
    case cantReach(SearchInput)

    /// The server refused the search, with its words.
    case refused(SearchInput, APIError.Refusal)
  }

  /// The text in the field.
  public var text: String

  public private(set) var phase = Phase.empty

  /// The item that was just added, until the user leaves the screen.
  public private(set) var added: AddedItem?

  /// The search that runs, so that a late answer of one that was stopped changes nothing.
  public private(set) var searching: UUID?

  public init(text: String = "") {
    self.text = text
  }

  /// A search of the field's text starts. Nil when the field is empty. The search's ID names its answer.
  public mutating func startSearch() -> (id: UUID, input: SearchInput)? {
    guard let input = SearchInput(text) else { return nil }
    let id = UUID()
    searching = id
    phase = .reading(input)
    return (id, input)
  }

  /// The search's answer. The form to push, or nil. The answer of a search that was stopped changes nothing.
  public mutating func searchEnded(_ id: UUID, with outcome: SearchOutcome) -> ItemDraft? {
    guard id == searching, case .reading(let input) = phase else { return nil }
    searching = nil
    switch outcome {
    case .found(let draft):
      phase = .empty
      return draft
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
      case .reading(let input), .cantReach(let input), .refused(let input, _): input
      case .empty: SearchInput(text)
      }
    searching = nil
    phase = .empty
    return input.map(ItemDraft.init(given:))
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
  /// Diagnostics: never here. The client reports each error as its side asks.
  public func search(_ input: SearchInput) async -> SearchOutcome {
    guard !hasEnded else { return .failed }
    do {
      let result = try await client.search(input.text)
      guard !hasEnded else { return .failed }
      return .found(ItemDraft(result: result))
    } catch {
      switch await writeOutcome(of: error) {
      case .unreachable: return .unreachable
      case .refused(let refusal): return .refused(refusal)
      case .failed: return .failed
      }
    }
  }

  /// Add: uploads each ticked image with `POST /images`, then adds the item to the user's primary list. The copy
  /// has the item at once. See "After Add" in `docs/spec.md`.
  ///
  /// The draft keeps the add's key and the images uploaded, so a second Add after a lost answer adds the item
  /// once. An image that the server can't fetch (`image_fetch_failed`) is left out, and the item is added without
  /// it.
  ///
  /// Diagnostics: never here. The client reports each error as its side asks.
  public func add(_ draft: inout ItemDraft) async -> AddOutcome {
    guard !hasEnded, let list = primaryList else { return .failed }
    do {
      var imageIDs: [String] = []
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
          continue
        }
      }
      let item = draft.newItem(imageIDs: imageIDs)
      let key = draft.key(for: item)
      let added = try await client.createItem(item, onList: list.id, key: key)
      guard !hasEnded else { return .failed }
      try await database.save([added], answering: true)
      // A sync that runs now may have asked before the add. Its pull keeps the item, and one more sync asks after it.
      syncAgainIfSyncing()
      return .added(AddedItem(id: added.resource.id, title: added.resource.title, listName: list.name))
    } catch {
      switch await writeOutcome(of: error) {
      case .unreachable: return .unreachable
      case .refused(let refusal): return .refused(refusal)
      case .failed: return .failed
      }
    }
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
