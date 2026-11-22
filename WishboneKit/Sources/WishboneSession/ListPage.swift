import Foundation
import WishboneAPI

// A list's page, from the copy: the name, the "For {names}" line, the description, the line for a viewer who can
// edit the list and is also a giver, and the items. See `docs/screens/list.md`, and in `docs/spec.md`: "Whose
// list: name the recipient", "Claim state on a child's list", and "How each thing is reached".
//
// **Claim state shows only as the server sends it**, as on a user's page: a recipient of the list sees none of it,
// and nothing here says who claimed.

/// What a list's page shows. The session model builds it from the copy: see `SessionModel.listPage(id:)`.
public struct ListPage: Equatable, Sendable {
  public let list: ListRow

  /// The list's recipients, in the order they became recipients, for the "For {names}" line.
  public let recipients: [Recipient]

  /// Whether the session's user is a recipient of the list. A recipient's rows have no claim state.
  public let isRecipient: Bool

  /// Whether the line "You see what's been claimed here. Fully claimed items don't show." shows above the items:
  /// the session's user can edit the list and is not a recipient, as a recipient's parent is.
  public let seesClaimsAsEditor: Bool

  /// The items, in the list's order. A giver's copy has no item that others claimed in full.
  public let items: [UserPage.Item]

  /// What the page says when the list has no items. Nil when it has some.
  public let noItems: NoItems?

  /// A recipient on the "For {names}" line.
  public struct Recipient: Equatable, Sendable, Identifiable {
    public let user: UserRow

    /// Whether the name links to the user's page: the session's user sees the user in full. A user whom the copy
    /// holds only as a summary has no page, so their name is only a name.
    public var isLinked: Bool { !user.isSummary }

    /// Whether "Deactivated" shows beside the name. Only a viewer who gets the user's `deactivated_at` sees it.
    public var isDeactivated: Bool { user.isDeactivated }

    public var id: String { user.id }
  }

  /// What the page says with no items.
  public enum NoItems: Equatable, Sendable {
    /// For a giver: "Nothing on this list yet."
    case forGiver

    /// For someone who can edit the list: "Nothing here yet. Tap Add item to start the list."
    case forEditor
  }

  /// The items in the order of the sort.
  public func items(sortedBy sort: ListSort) -> [UserPage.Item] {
    sort.sorted(items)
  }
}

/// The order of a list's items on its page. It belongs to one window's page, and is never saved. See Sort in
/// `docs/screens/list.md`.
public enum ListSort: String, Equatable, Sendable, CaseIterable, Identifiable {
  /// The list's own order, as its editors set it.
  case listOrder

  /// The lowest price first, and the items with no price last.
  case price

  /// The item added last first. Items added in the same instant go by ID, the higher first, since the server gives
  /// a later item a higher one.
  case newest

  public var id: String { rawValue }

  /// The items in this order. Items that tie keep the list's order.
  public func sorted(_ items: [UserPage.Item]) -> [UserPage.Item] {
    let ordered = items.sorted { ($0.row.position, $0.row.id) < ($1.row.position, $1.row.id) }
    switch self {
    case .listOrder:
      return ordered
    case .price:
      return Self.stable(ordered) { first, second in
        switch (first.row.priceMinor, second.row.priceMinor) {
        case (let first?, let second?): first < second
        case (.some, .none): true
        default: false
        }
      }
    case .newest:
      return Self.stable(ordered) { first, second in
        guard first.row.createdAt == second.row.createdAt else { return first.row.createdAt > second.row.createdAt }
        return first.row.id.compare(second.row.id, options: .numeric) == .orderedDescending
      }
    }
  }

  /// A stable sort: items that `isBefore` doesn't order keep their order.
  private static func stable(
    _ items: [UserPage.Item], by isBefore: (UserPage.Item, UserPage.Item) -> Bool
  ) -> [UserPage.Item] {
    items.enumerated().sorted { first, second in
      if isBefore(first.element, second.element) { return true }
      if isBefore(second.element, first.element) { return false }
      return first.offset < second.offset
    }
    .map(\.element)
  }
}

extension SessionModel {
  /// The list's page, from the copy. Nil when the page is the "not found" page: the list is not in the copy, which
  /// is the same for a list that was deleted and one that the session's user can't see.
  public func listPage(id: String) -> ListPage? {
    guard let list = list(id: id) else { return nil }
    let isRecipient = list.recipientIDs.contains(session.userID)
    let items = items(onList: id).map { item in
      UserPage.Item(row: item, claim: isRecipient ? nil : UserPage.Claim(item))
    }
    let noItems: ListPage.NoItems? = items.isEmpty ? (list.canEdit ? .forEditor : .forGiver) : nil
    return ListPage(
      list: list,
      recipients: list.recipientIDs.compactMap { user(id: $0) }.map(ListPage.Recipient.init),
      isRecipient: isRecipient,
      seesClaimsAsEditor: list.canEdit && !isRecipient,
      items: items,
      noItems: noItems
    )
  }
}
