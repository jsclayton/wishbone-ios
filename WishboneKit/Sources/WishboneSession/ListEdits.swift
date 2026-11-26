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

extension SessionModel {
  /// The longest name of a list, in characters, as the server takes it.
  public static let listNameLimit = 100

  /// The longest description of a list, in characters, as the server takes it.
  public static let listDescriptionLimit = 2000

  /// Edit list: saves a new name and description, as an unsent change. Only the fields that change are sent. A
  /// name is trimmed, and a blank one changes nothing. A blank description clears it.
  ///
  /// It does nothing for a list that the copy doesn't hold, that the user can't edit, or that the edit doesn't
  /// change. It returns when the change is in the journal and published, and doesn't wait for the sync.
  public func editList(_ id: String, name: String, description: String) async {
    guard !hasEnded, let list = list(id: id), list.canEdit else { return }
    let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.listNameLimit))
    let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
    let description = trimmed.isEmpty ? nil : String(description.prefix(Self.listDescriptionLimit))
    var changes = ListChanges()
    if !name.isEmpty, name != list.name { changes.name = name }
    if description != list.description { changes.description = description ?? "" }
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
