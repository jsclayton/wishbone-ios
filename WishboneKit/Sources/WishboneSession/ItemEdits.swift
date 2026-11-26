import Foundation
import WishboneAPI

// Edit item, and Delete, on an item's page and in its row's context menu. See "Edit item" and Actions in
// `docs/screens/item.md`, and in `docs/spec.md`: "Unsent changes", and "A page that goes away under a window".
//
// **Each is an unsent change.** It shows at once, in every window, and a sync sends it, now or when the instance
// answers. A refusal rolls it back, and shows once (see `UnsentChanges.swift`).
//
// **An edit sends only the fields that change**, as one merge patch. A new photo is uploaded first: its upload is
// an unsent change of its own, just before the edit, which names the photo by a stand-in ID until the upload's
// answer gives the server's.
//
// **A delete never depends on the item's gifts.** Nothing here reads them. A deleted item leaves every window: a
// window that shows its page shows the "not found" page.
//
// An item that a create in the journal adds is edited and deleted by its stand-in ID, and the create's answer puts
// the server's ID in its place in these changes (see `StandIn`).

/// What the Edit item sheet holds. Nothing is saved until Save. It starts as the item is, and the sheet keeps it as
/// its own state. See "Edit item" in `docs/screens/item.md`.
public struct ItemEditDraft: Sendable, Equatable {
  /// The most photos that an item can have, as the server takes them.
  public static let photoLimit = 5

  /// The most that the Edit item sheet offers for how many are wanted.
  public static let quantityLimit = 999

  /// A photo of the item: one that the server has, or one that the user just took or chose, which Save uploads.
  public enum PhotoEntry: Sendable, Equatable, Identifiable {
    case saved(ImageSummary)
    case new(Photo)

    public var id: String {
      switch self {
      case .saved(let image): image.id
      case .new(let photo): "new-\(photo.id.uuidString)"
      }
    }
  }

  /// The photos, in the order they were added. A new one goes at the end.
  public private(set) var photos: [PhotoEntry]

  /// The primary photo, by its entry's ID. Nil when there is no photo.
  public private(set) var primaryID: String?

  public var title: String
  public var priceMinor: Int?

  /// The top of a price range, for "Up to".
  public var topPriceMinor: Int?

  /// The price's ISO 4217 code: the item's, or USD.
  public let currency: String

  /// How many are wanted, at least 1. It is kept while the item is always wanted, so the switch can go back.
  public var quantity: Int

  /// Always wanted: an unlimited item.
  public var isUnlimited: Bool
  public var notes: String

  /// The draft of the item, as it is now.
  public init(_ item: ItemRow) {
    photos = item.images.map(PhotoEntry.saved)
    primaryID = (item.primaryImage ?? item.images.first)?.id
    title = item.title
    priceMinor = item.priceMinor
    topPriceMinor = item.topPriceMinor
    currency = item.currency ?? "USD"
    quantity = item.quantity
    isUnlimited = item.isUnlimited
    notes = item.notes ?? ""
  }

  /// The primary photo. Nil when there is no photo.
  public var primary: PhotoEntry? {
    photos.first { $0.id == primaryID }
  }

  /// Whether one more photo can be added: the item has fewer than 5.
  public var canAddPhoto: Bool {
    photos.count < Self.photoLimit
  }

  /// Adds the photo at the end. A first photo is the primary one. It does nothing when the item has 5 already.
  public mutating func add(_ photo: Photo) {
    guard canAddPhoto else { return }
    photos.append(.new(photo))
    if primaryID == nil { primaryID = photos.last?.id }
  }

  /// Removes the photo. When it was the primary one, the first photo left takes its place, as the server does.
  public mutating func remove(_ id: String) {
    photos.removeAll { $0.id == id }
    if primaryID == id { primaryID = photos.first?.id }
  }

  /// Makes the photo the primary one.
  public mutating func makePrimary(_ id: String) {
    guard photos.contains(where: { $0.id == id }) else { return }
    primaryID = id
  }

  /// Whether Save can go: the item has a title.
  public var hasTitle: Bool {
    !title.allSatisfy(\.isWhitespace)
  }
}

extension SessionModel {
  /// Edit item: saves what the draft changes, as an unsent change. Only the fields that change are sent, in one
  /// merge patch. A title is trimmed, and a blank one can't be saved. Blank notes clear them. A cleared price clears
  /// the top price with it. A new photo is uploaded first, as an unsent change of its own.
  ///
  /// It does nothing for an item that the copy doesn't hold, that the user can't edit, or that the draft doesn't
  /// change, and for a draft with no title or more than 5 photos. It returns when the change is in the journal and
  /// published, and doesn't wait for the sync.
  public func editItem(_ id: String, _ draft: ItemEditDraft) async {
    guard !hasEnded, let item = item(id: id), item.canEdit, draft.photos.count <= ItemEditDraft.photoLimit else {
      return
    }
    let title = String(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ItemDraft.titleLimit))
    guard !title.isEmpty else { return }
    var changes = ItemChanges()
    if title != item.title { changes.title = title }

    let trimmed = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
    let notes = trimmed.isEmpty ? nil : String(trimmed.prefix(ItemDraft.notesLimit))
    if notes != item.notes { changes.notes = notes ?? "" }

    if draft.priceMinor != item.priceMinor { changes.priceMinor = .some(draft.priceMinor) }
    let topPriceMinor = draft.priceMinor == nil ? nil : draft.topPriceMinor
    if topPriceMinor != item.topPriceMinor { changes.topPriceMinor = .some(topPriceMinor) }
    if draft.priceMinor != nil, draft.currency != (item.currency ?? "USD") { changes.currency = draft.currency }

    if draft.isUnlimited != item.isUnlimited { changes.isUnlimited = draft.isUnlimited }
    if !draft.isUnlimited, draft.quantity != item.quantity { changes.quantity = max(1, draft.quantity) }

    // A new photo gets a stand-in ID, which the edit names, and an upload of its own just before the edit.
    var uploads: [LocalDatabase.NewChange] = []
    var imageIDs: [String: String] = [:]
    for entry in draft.photos {
      switch entry {
      case .saved(let image):
        imageIDs[entry.id] = image.id
      case .new(let photo):
        let standIn = StandIn.make()
        imageIDs[entry.id] = standIn
        uploads.append(.init(.uploadImage(imageID: standIn), title: item.title, file: photo.data))
      }
    }
    let ids = draft.photos.compactMap { imageIDs[$0.id] }
    if ids != item.images.map(\.id) { changes.imageIDs = ids }
    let primary = draft.primaryID.flatMap { imageIDs[$0] }
    if let primary, primary != (item.primaryImage ?? item.images.first)?.id { changes.primaryImageID = primary }

    guard !changes.isEmpty else { return }
    await record(uploads + [.init(.editItem(itemID: item.id, changes: changes), title: item.title)])
  }

  /// Delete: deletes the item, as an unsent change. It leaves the copy at once, in every window, and a window that
  /// shows its page shows the "not found" page. Nothing here depends on the item's gifts.
  ///
  /// It does nothing for an item that the copy doesn't hold, or that the user can't delete. It returns when the
  /// change is in the journal and published, and doesn't wait for the sync.
  public func deleteItem(_ id: String) async {
    guard !hasEnded, let item = item(id: id), item.canDelete else { return }
    await record(.deleteItem(itemID: item.id, listID: item.listID), title: item.title)
  }
}
