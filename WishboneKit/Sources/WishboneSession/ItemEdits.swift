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

/// What the Edit item sheet holds. Nothing is saved until Save. It starts as the item is, with the photos whose
/// uploads wait in the journal, and the sheet keeps it as its own state: see `SessionModel.editDraft(ofItem:)`. See
/// "Edit item" in `docs/screens/item.md`.
public struct ItemEditDraft: Sendable, Equatable {
  /// The most photos that an item can have, as the server takes them.
  public static let photoLimit = 5

  /// The most that the Edit item sheet offers for how many are wanted.
  public static let quantityLimit = 999

  /// A photo of the item: one that the server has, one whose upload waits, or one that the user just took or chose,
  /// which Save uploads.
  public enum PhotoEntry: Sendable, Equatable, Identifiable {
    case saved(ImageSummary)

    /// A photo that an unsent change gave the item, whose upload waits in the journal, by the image's stand-in ID.
    /// Once its upload is sent, while the change that names it still waits, it is named by the server's ID. Its
    /// bytes are in the journal until the upload is sent (`SessionModel.waitingPhoto(_:)`).
    case waiting(String)

    case new(Photo)

    public var id: String {
      switch self {
      case .saved(let image): image.id
      case .waiting(let id): id
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

  /// The draft of the item, as the copy shows it, with the photos that the journal gives it: each by its ID, in
  /// order, the primary one by its ID. A photo that the row holds is saved, and any other waits.
  init(_ item: ItemRow, imageIDs: [String], primaryImageID: String?) {
    photos = imageIDs.map { id in item.images.first { $0.id == id }.map(PhotoEntry.saved) ?? .waiting(id) }
    primaryID = primaryImageID.flatMap { id in imageIDs.contains(id) ? id : nil } ?? imageIDs.first
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

  /// The title as it is saved: with no space at either end, and at most 300 characters.
  fileprivate var savedTitle: String {
    String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ItemDraft.titleLimit))
  }

  /// The notes as they are saved: nil when blank, and at most 2000 characters.
  fileprivate var savedNotes: String? {
    let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : String(trimmed.prefix(ItemDraft.notesLimit))
  }

  /// The top price as it is saved: none without a price.
  fileprivate var savedTopPriceMinor: Int? {
    priceMinor == nil ? nil : topPriceMinor
  }
}

extension SessionModel {
  /// The draft that the Edit item sheet opens with: the item as the copy shows it, with every photo that the user
  /// gave it. The copy's row shows a photo only once the server has it, so the photos come from the journal: the
  /// image IDs that the item's create, or the last edit of its photos, names. A photo whose upload waits is a
  /// `waiting` entry, and so is one whose upload is sent while the change that names it waits. A photo whose upload
  /// the server refused is left out, as the change that names it is sent without it. With no such change, the photos
  /// are the row's. Nil for an item that the copy doesn't hold.
  public func editDraft(ofItem id: String) async -> ItemEditDraft? {
    guard !hasEnded, item(id: id) != nil else { return nil }
    let changes: [UnsentChange]
    let standIns: [String: String]
    do {
      (changes, standIns) = try await database.unsentChangesAndStandIns()
    } catch {
      Log.fault(.session, "The journal can't be read.", detail: "\(error)")
      (changes, standIns) = ([], replacedStandIns)
    }
    guard !hasEnded, let item = item(id: id) else { return nil }
    var imageIDs = item.images.map(\.id)
    var primaryImageID = (item.primaryImage ?? item.images.first)?.id
    for change in changes {
      switch change.action {
      case .createItem(let created) where created.id == item.id:
        imageIDs = created.imageIDs
        primaryImageID = created.imageIDs.first
      case .editItem(let target, let edit) where target == item.id:
        if let ids = edit.imageIDs {
          imageIDs = ids
          if !ids.contains(where: { $0 == primaryImageID }) { primaryImageID = ids.first }
        }
        if let primary = edit.primaryImageID { primaryImageID = primary }
      default:
        continue
      }
    }
    let uploads = Set(
      changes.compactMap { change -> String? in
        if case .uploadImage(let id) = change.action { id } else { nil }
      })
    // Read with the changes: the copy's observation may not have published a stand-in that was just replaced.
    let replaced = Set(standIns.values)
    let kept = imageIDs.filter { id in
      item.images.contains { $0.id == id } || uploads.contains(id) || replaced.contains(id)
    }
    return ItemEditDraft(item, imageIDs: kept, primaryImageID: primaryImageID)
  }

  /// The bytes of a photo whose upload waits in the journal, by the image's stand-in ID, for the Edit item sheet to
  /// show. Nil once the upload is sent, or refused.
  public func waitingPhoto(_ id: String) async -> Data? {
    guard !hasEnded else { return nil }
    return try? await database.unsentFile(id)
  }

  /// Edit item: saves what the user changed in the sheet, as an unsent change. Only the fields where `draft` differs
  /// from `opened`, the draft that the sheet opened with, are sent, in one merge patch. So a field that changed
  /// elsewhere while the sheet was open, which a sync brought, is never sent back. A title is trimmed, and a blank
  /// one can't be saved. Blank notes clear them. A cleared price clears the top price with it. A new photo is
  /// uploaded first, as an unsent change of its own. A photo whose upload waits keeps its ID.
  ///
  /// It does nothing for an item that the copy doesn't hold, that the user can't edit, or that the user didn't
  /// change, and for a draft with no title or more than 5 photos. It returns when the change is in the journal and
  /// published, and doesn't wait for the sync.
  public func editItem(_ id: String, from opened: ItemEditDraft, to draft: ItemEditDraft) async {
    guard !hasEnded, let item = item(id: id), item.canEdit, draft.photos.count <= ItemEditDraft.photoLimit else {
      return
    }
    let title = draft.savedTitle
    guard !title.isEmpty else { return }
    var changes = ItemChanges()
    if title != opened.savedTitle { changes.title = title }
    if draft.savedNotes != opened.savedNotes { changes.notes = draft.savedNotes ?? "" }

    if draft.priceMinor != opened.priceMinor { changes.priceMinor = .some(draft.priceMinor) }
    if draft.savedTopPriceMinor != opened.savedTopPriceMinor {
      changes.topPriceMinor = .some(draft.savedTopPriceMinor)
    }

    if draft.isUnlimited != opened.isUnlimited { changes.isUnlimited = draft.isUnlimited }
    if !draft.isUnlimited, draft.quantity != opened.quantity { changes.quantity = max(1, draft.quantity) }

    // A new photo gets a stand-in ID, which the edit names, and an upload of its own just before the edit.
    var uploads: [LocalDatabase.NewChange] = []
    var imageIDs: [String: String] = [:]
    for entry in draft.photos {
      switch entry {
      case .saved, .waiting:
        imageIDs[entry.id] = entry.id
      case .new(let photo):
        let standIn = StandIn.make()
        imageIDs[entry.id] = standIn
        uploads.append(.init(.uploadImage(imageID: standIn), title: item.title, file: photo.data))
      }
    }
    if draft.photos.map(\.id) != opened.photos.map(\.id) {
      changes.imageIDs = draft.photos.compactMap { imageIDs[$0.id] }
    }
    if draft.primaryID != opened.primaryID, let primary = draft.primaryID.flatMap({ imageIDs[$0] }) {
      changes.primaryImageID = primary
    }

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
