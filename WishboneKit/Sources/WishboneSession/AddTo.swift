import Foundation
import WishboneAPI

// Which list an add goes to, and the duplicate hint. See "Which list", "Whose list: name the recipient", and "What
// the add form holds" in `docs/spec.md`, and `docs/screens/add-form.md`.
//
// **Secrecy.** Add to offers only the lists that the user can edit. The hint reads only the copy, which holds only
// what the user sees on the list: a parent who is a giver on a child's list gets no hint for a fully claimed item,
// because the server hides it. The hint never says why it is silent.

/// The lists that Add to offers: every list the user can edit, in the Lists tab's order. The session model builds
/// it from the copy: see `SessionModel.addTo(for:)`.
public struct AddTo: Equatable, Sendable {
  /// A list that an add can go to.
  public struct Target: Equatable, Sendable, Identifiable {
    public let list: ListRow

    /// Whether the session's user is one of the list's recipients.
    public let isMine: Bool

    /// The names of the list's recipients, in the order they became recipients, when the session's user is not a
    /// recipient: "Lego · Emma". Empty for a list of the user's own.
    public let recipientNames: [String]

    public var id: String { list.id }
  }

  /// A child's part: the child, and the child's lists that the user can edit, as the Lists tab has them.
  public struct ChildPart: Equatable, Sendable, Identifiable {
    public let child: UserRow
    public let targets: [Target]

    public var id: String { child.id }
  }

  /// The user's own lists that they can edit: the primary list first, then the extra lists, by name.
  public let yourLists: [Target]

  /// A part for each child with a list that the user can edit, in the Lists tab's order. A list that two children
  /// share is offered once, in the first child's part.
  public let children: [ChildPart]

  /// Every list offered, in order.
  public var targets: [Target] {
    yourLists + children.flatMap(\.targets)
  }
}

/// "Already on this list: {title}": the list that the add goes to has an item with the same link, or the same title.
/// It never blocks the add.
public struct DuplicateHint: Equatable, Sendable {
  /// The item that is already on the list.
  public let itemID: String
  public let title: String

  /// Whether the hint opens the item. On the Add screen, it does. In a sheet it is text, because a sheet never
  /// opens a second sheet.
  public let opensItem: Bool
}

extension SessionModel {
  /// Every list that the user can edit, for Add to: the Lists tab's lists, with only the ones that the user can
  /// edit. A list is offered once, so a child whose every list that the user can edit was offered under an earlier
  /// child has no part: in the standard family, the deactivated child shares a list with the first child.
  ///
  /// A list for someone else whose recipients' names aren't in the copy is left out, so it never looks like one of
  /// the user's own lists.
  public var addTo: AddTo {
    let tab = listsTab
    var offered = Set<String>()
    func targets(_ lists: [ListRow]) -> [AddTo.Target] {
      lists.filter(\.canEdit).compactMap { list in
        let target = target(list)
        guard target.isMine || !target.recipientNames.isEmpty else { return nil }
        guard offered.insert(list.id).inserted else { return nil }
        return target
      }
    }
    let yours = targets(tab.yourLists)
    let children = tab.children.compactMap { part -> AddTo.ChildPart? in
      let lists = targets(part.lists)
      return lists.isEmpty ? nil : AddTo.ChildPart(child: part.child, targets: lists)
    }
    return AddTo(yourLists: yours, children: children)
  }

  /// Add to for the form, or nil when it is hidden: the form is fixed to a list, or the user can edit only one.
  public func addTo(for draft: ItemDraft) -> AddTo? {
    guard !draft.isFixedToList else { return nil }
    let addTo = addTo
    return addTo.targets.count > 1 ? addTo : nil
  }

  /// The list that the form's add goes to, with its recipients' names: the one picked or fixed, or the primary
  /// list. Nil while the copy doesn't hold it.
  public func target(of draft: ItemDraft) -> AddTo.Target? {
    guard let id = draft.listID ?? primaryList?.id else { return nil }
    return target(ofList: id)
  }

  /// The list as a target of an add, with its recipients' names: for the line "Adding to {list}" in a list's
  /// sheet. Nil while the copy doesn't hold it.
  public func target(ofList id: String) -> AddTo.Target? {
    list(id: id).map(target)
  }

  /// The duplicate hint for the form: the first item, in the list's order, on the list that the add goes to with
  /// one of its store links at the form's link, as `POST /search` gives it, or with the form's title, with case and
  /// extra spaces ignored. Nil when there is none.
  public func duplicateHint(for draft: ItemDraft) -> DuplicateHint? {
    guard let list = target(of: draft)?.list else { return nil }
    let link = draft.storeLink?.url
    let title = DuplicateHint.comparable(draft.title)
    let match = items(onList: list.id).first { item in
      if let link, storeLinks(ofItem: item.id).contains(where: { $0.url == link }) { return true }
      return !title.isEmpty && DuplicateHint.comparable(item.title) == title
    }
    return match.map { DuplicateHint(itemID: $0.id, title: $0.title, opensItem: !draft.isFixedToList) }
  }

  private func target(_ list: ListRow) -> AddTo.Target {
    let isMine = list.recipientIDs.contains(session.userID)
    return AddTo.Target(
      list: list, isMine: isMine, recipientNames: isMine ? [] : list.recipientIDs.compactMap { user(id: $0)?.name })
  }
}

extension DuplicateHint {
  /// A title as the hint compares it: in lowercase, with each run of spaces as one space, and none at either end.
  static func comparable(_ title: String) -> String {
    title.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}
