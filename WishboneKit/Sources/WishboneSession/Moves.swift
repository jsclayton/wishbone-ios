import Foundation
import WishboneAPI

// Move to…: an item goes to the end of another list that the user can edit. See "A drag between lists is a move",
// "Every drag has a way without dragging", "What the windows show after a drop" and "A page that goes away under a
// window" in `docs/spec.md`, and Move to… in `docs/screens/item.md` and `docs/screens/list.md`.
//
// **It is an unsent change.** The item shows at the end of the list picked at once, in every window, and a sync sends
// it, now or when the instance answers: `PATCH /items/{id}` with only `list_id`, its own `Idempotency-Key`, and no
// `If-Match`, so someone else's edit never blocks it. When the server accepts it, the copy takes the returned item and
// applies the server's shift rule (`ShiftRule`). A refusal (403 `cannot_edit_target_list`, or 404) rolls it back in
// every window, and shows once.
//
// **No word about gifts.** Nothing here reads the item's gifts, and nothing asks first: a warning would show a
// recipient that the item is claimed. The server's open gifts follow the item, and the next pull brings them.

/// The server's shift rule for a move, as the copy applies it when the server accepts one: the gap closes on the old
/// list, and the items on the new one shift to make room. A reorder on one list is the same rule. It is pure: the
/// places of the other items go in, and their new places come out. See "What the windows show after a drop" in
/// `docs/spec.md`.
public enum ShiftRule {
  /// An item's place: its list, and its position on it, from 0.
  public struct Place: Sendable, Equatable {
    public let id: String
    public let listID: String
    public let position: Int

    public init(id: String, listID: String, position: Int) {
      self.id = id
      self.listID = listID
      self.position = position
    }
  }

  /// The other items' places after the item moved from `old` to `new`, in the order given. Every item after the
  /// item's old place on its old list goes up one place, and then every item at its new place or after it on its new
  /// list goes down one. The items of other lists stay where they are. On one list, this is the server's reorder.
  public static func shifting(_ others: [Place], moving old: Place, to new: Place) -> [Place] {
    closing(others, leaving: old).map { place in
      guard place.listID == new.listID, place.position >= new.position else { return place }
      return Place(id: place.id, listID: place.listID, position: place.position + 1)
    }
  }

  /// The other items' places after the item left its place, in the order given: the first half of the rule. Every
  /// item after the place on its list goes up one, as the server closes the gap that a delete leaves.
  public static func closing(_ others: [Place], leaving old: Place) -> [Place] {
    others.map { place in
      guard place.listID == old.listID, place.position > old.position else { return place }
      return Place(id: place.id, listID: place.listID, position: place.position - 1)
    }
  }
}

extension SessionModel {
  /// The lists that Move to… offers for the item: every list that the user can edit but the one it is on, each with
  /// its recipients' names when the user is not one, in Add to's order. Nil when Move to… is not offered: the item is
  /// not in the copy, the user can't edit it, or no other list can take it.
  public func moveTargets(ofItem id: String) -> AddTo? {
    guard !hasEnded, let item = item(id: id), item.canEdit else { return nil }
    let addTo = addTo
    let yours = addTo.yourLists.filter { $0.id != item.listID }
    let children = addTo.children.compactMap { part -> AddTo.ChildPart? in
      let targets = part.targets.filter { $0.id != item.listID }
      return targets.isEmpty ? nil : AddTo.ChildPart(child: part.child, targets: targets)
    }
    guard !yours.isEmpty || !children.isEmpty else { return nil }
    return AddTo(yourLists: yours, children: children)
  }

  /// Move to…: moves the item to the end of the list, as an unsent change. It shows there at once, in every window,
  /// and a page that shows the item stays, with the new list's name. It asks nothing first, and says nothing about
  /// gifts.
  ///
  /// A sync sends it. When the server refuses it in that sync while `window` is in the foreground, the refusal shows
  /// there at once, in the window that moved the item. Otherwise it shows as every late refusal does. It returns when
  /// the change is in the journal and published, and doesn't wait for the sync.
  ///
  /// It does nothing for an item that the copy doesn't hold, that the user can't edit, or that is on the list
  /// already, and for a list that Move to… doesn't offer.
  public func moveItem(_ id: String, toList listID: String, from window: UUID? = nil) async {
    guard let item = item(id: id), item.listID != listID,
      let target = moveTargets(ofItem: id)?.targets.first(where: { $0.id == listID })
    else { return }
    let move = ItemMove(itemID: item.id, fromListID: item.listID, toListID: listID, toListName: target.list.name)
    do {
      try await database.record([LocalDatabase.NewChange(.moveItem(move), title: item.title)])
    } catch {
      Log.fault(.session, "The journal can't take an unsent change.", detail: "\(error)")
      return
    }
    await publishNow()
    Task {
      await syncNow()
      guard let window, windowsInForeground.contains(window) else { return }
      await showLateRefusals(in: window)
    }
  }
}

extension SessionModel {
  /// Reorder: puts the item at another place on its own list, as an unsent change. It shows there at once, in every
  /// window, and the other items on the list shift as the server's shift rule moves them. It asks nothing first, and
  /// says nothing about gifts. See "Every drag has a way without dragging" and "Where an item can land" in
  /// `docs/spec.md`, and Reorder in `docs/screens/list.md`.
  ///
  /// The offset is where the item goes among the list's items in List order, as the list's page shows them, before
  /// the item moves: before the item at that index, or after the last for the index past the end. It is the
  /// destination of a list's move. The place that the change sends is the server's: the place of the item that it
  /// goes before, or after, so items that the user doesn't see, such as the ones that others claimed in full, keep
  /// their order around it.
  ///
  /// A sync sends it, with only `position`. When the server refuses it in that sync while `window` is in the
  /// foreground, the refusal shows there at once, as a move's does. It returns when the change is in the journal and
  /// published, and doesn't wait for the sync.
  ///
  /// It does nothing for an item that the copy doesn't hold, on a list that the user can't edit, or for an offset
  /// that leaves the item where it is.
  public func reorderItem(_ id: String, toOffset offset: Int, from window: UUID? = nil) async {
    guard !hasEnded, let item = item(id: id), item.canEdit, list(id: item.listID)?.canEdit == true else { return }
    let items = items(onList: item.listID)
    guard let index = items.firstIndex(where: { $0.id == item.id }), offset >= 0, offset <= items.count,
      offset != index, offset != index + 1
    else { return }
    // Down the list, the item takes the place of the one that it goes after, and up it, of the one it goes before.
    let position = offset > index ? items[offset - 1].position : items[offset].position
    do {
      try await database.record([
        LocalDatabase.NewChange(.reorderItem(itemID: item.id, position: position), title: item.title)
      ])
    } catch {
      Log.fault(.session, "The journal can't take an unsent change.", detail: "\(error)")
      return
    }
    await publishNow()
    Task {
      await syncNow()
      guard let window, windowsInForeground.contains(window) else { return }
      await showLateRefusals(in: window)
    }
  }
}

extension ListPage {
  /// Whether the page offers Reorder, the toolbar's Edit button: the user can edit the list, and the page shows it in
  /// List order. A list shown by price or by newest takes no reorder. See Reorder in `docs/screens/list.md`.
  public func offersReorder(sortedBy sort: ListSort) -> Bool {
    sort == .listOrder && list.canEdit
  }
}
