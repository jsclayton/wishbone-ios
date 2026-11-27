import Foundation
import WishboneAPI

// Edit list, and Delete list, on a list's page. See `docs/screens/list.md`, and in `docs/spec.md`: "Unsent changes",
// "A page that goes away under a window", and "The rest, as the server has it".
//
// **Each is an unsent change.** It shows at once, in every window, and a sync sends it, now or when the instance
// answers. A refusal rolls it back, and shows once (see `UnsentChanges.swift`).
//
// **A delete never depends on the list's gifts.** The server never refuses one because of them, and nothing here
// reads them. A deleted list leaves every window: a window that shows its page shows the "not found" page.

extension ListPage {
  /// Whether Delete list shows: the list's `can_delete`, and never on a primary list, which the server never
  /// deletes.
  public var canDelete: Bool { list.canDelete && !list.isPrimary }
}

/// What the Edit list sheet holds: the name and the description, as the user types them. The sheet keeps the draft
/// it opened with, so that Save sends only what the user changed (`SessionModel.editList(_:from:to:)`).
public struct ListEditDraft: Sendable, Equatable {
  public var name: String
  public var description: String

  public init(name: String, description: String) {
    self.name = name
    self.description = description
  }

  /// The list as the copy shows it.
  public init(_ list: ListRow) {
    self.init(name: list.name, description: list.description ?? "")
  }

  /// The name as it is saved: trimmed, and cut to the server's limit. Empty for a blank name, which can't be saved.
  var savedName: String {
    String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SessionModel.listNameLimit))
  }

  /// The description as it is saved: none for a blank one, and cut to the server's limit.
  var savedDescription: String? {
    description.allSatisfy(\.isWhitespace) ? nil : String(description.prefix(SessionModel.listDescriptionLimit))
  }
}

extension SessionModel {
  /// The longest name of a list, in characters, as the server takes it.
  nonisolated public static let listNameLimit = 100

  /// The longest description of a list, in characters, as the server takes it.
  nonisolated public static let listDescriptionLimit = 2000

  /// Edit list: saves what the user changed in the sheet, as an unsent change. Only the fields where `draft`
  /// differs from `opened`, the draft that the sheet opened with, are sent. So a field that changed elsewhere while
  /// the sheet was open, which a sync brought, is never sent back. A name is trimmed, and a blank one changes
  /// nothing. A blank description clears it.
  ///
  /// It does nothing for a list that the copy doesn't hold, that the user can't edit, or that the user didn't
  /// change. It returns when the change is in the journal and published, and doesn't wait for the sync.
  public func editList(_ id: String, from opened: ListEditDraft, to draft: ListEditDraft) async {
    guard !hasEnded, let list = list(id: id), list.canEdit else { return }
    var changes = ListChanges()
    let name = draft.savedName
    if !name.isEmpty, name != opened.savedName { changes.name = name }
    if draft.savedDescription != opened.savedDescription { changes.description = draft.savedDescription ?? "" }
    guard !changes.isEmpty else { return }
    await record(.editList(listID: list.id, changes: changes), title: list.name)
  }

  /// Delete list: deletes the extra list and its items, as an unsent change. The list leaves the copy at once, in
  /// every window, and a window that shows its page shows the "not found" page.
  ///
  /// It does nothing for a list that the copy doesn't hold, that the user can't delete, or that is a primary list.
  /// It returns when the change is in the journal and published, and doesn't wait for the sync.
  public func deleteList(_ id: String) async {
    guard !hasEnded, let page = listPage(id: id), page.canDelete else { return }
    await record(.deleteList(listID: page.list.id), title: page.list.name)
  }
}
