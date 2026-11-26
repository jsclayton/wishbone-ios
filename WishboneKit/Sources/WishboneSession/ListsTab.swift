import Foundation
import WishboneAPI

// The Lists tab: every list that the session's user can edit, and the invitations that wait. The invitations for the
// user and their children first, then their own lists, then a part for each child. See
// "Tabs that become a sidebar" and "A deactivated child" in `docs/spec.md`, and `docs/screens/lists.md`.
//
// **No claim state.** A row has the list's `item_count` as the server sends it. A giver's count on a child's list
// can be lower than the child's own, because a giver doesn't see an item that others claimed in full. The tab
// shows the count with no comment.

/// What the Lists tab shows. The session model builds it from the copy: see `SessionModel.listsTab`.
public struct ListsTab: Equatable, Sendable {
  /// The pending invitations for the user and for their children, the oldest first. The part shows only while one
  /// is pending.
  public let invitations: [PendingInvitation]

  /// The lists that the session's user is a recipient of: the primary list first, then the extra lists, by name.
  public let yourLists: [ListRow]

  /// One part for each of the user's children, in the server's order. A deactivated child's part stays.
  public let children: [ChildPart]

  /// A child's part: the child, and the lists that the child is a recipient of and the session's user is not.
  public struct ChildPart: Equatable, Sendable, Identifiable {
    public let child: UserRow

    /// The child's primary list first, then the child's extra lists, by name. A list that the session's user is
    /// also a recipient of is under the user's own lists, not here.
    public let lists: [ListRow]

    public var id: String { child.id }
  }

  /// Whether the tab has no row. Every user has a primary list, so after the first sync it always has one.
  public var isEmpty: Bool {
    yourLists.isEmpty && children.allSatisfy(\.lists.isEmpty)
  }
}

extension SessionModel {
  /// The Lists tab, from the copy.
  ///
  /// - Your lists are `yourLists`: the primary list first, then the extra lists, by name.
  /// - Each child of the session's user has a part, under the child's name, while the copy holds the child in
  ///   full. A deactivated child's part stays, with its lists.
  /// - A list that has both the user and the child as recipients shows once, under the user's own lists. A list
  ///   that two children share shows in each child's part.
  public var listsTab: ListsTab {
    let me = session.userID
    let children = (user?.record?.childIDs ?? []).compactMap { id -> ListsTab.ChildPart? in
      guard id != me, let child = user(id: id), !child.isSummary else { return nil }
      let theirs = lists.filter { $0.recipientIDs.contains(id) && !$0.recipientIDs.contains(me) }
      let primaryID = child.record?.primaryListID
      let isPrimary = { (list: ListRow) in primaryID.map { list.id == $0 } ?? list.isPrimary }
      return ListsTab.ChildPart(
        child: child, lists: theirs.filter(isPrimary) + theirs.filter { !isPrimary($0) })
    }
    return ListsTab(invitations: pendingInvitations, yourLists: yourLists, children: children)
  }
}
