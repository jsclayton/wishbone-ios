import Foundation
import WishboneAPI

// A list's page, from the copy: the name, the "For {names}" line, the description, the line that says why items
// can be missing, and the items. See `docs/screens/list.md`, and in `docs/spec.md`: "Whose
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
  /// the session's user is not a recipient, and can edit the list or is a parent of one of its recipients. The
  /// second covers a parent of a deactivated child, who can't edit the child's lists. It is the user page's rule.
  public let seesWhyItemsAreMissing: Bool

  /// The items, in the list's order. A giver's copy has no item that others claimed in full.
  public let items: [UserPage.Item]

  /// What the page says when the list has no items. Nil when it has some.
  public let noItems: NoItems?

  /// Leave: the session's user, when the list's `can_leave` is true. Nil otherwise.
  public let leave: Leaver?

  /// Make {child} leave: each of the user's children whose recipient row has `can_delete`.
  public let makeLeave: [Leaver]

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

  /// The names on the "For {names}" line, as the locale lists them. Only a linked recipient's name carries a link,
  /// and the link covers the name alone, never its "(Deactivated)" or the words between names.
  ///
  /// - Parameters:
  ///   - recipients: The recipients, in the line's order.
  ///   - deactivated: The words for a deactivated recipient, from their name: "{name} (Deactivated)".
  ///   - link: The link for the recipient with the user ID.
  public static func forLineNames(
    of recipients: [Recipient], deactivated: (String) -> String, link: (String) -> URL?
  ) -> AttributedString {
    forLineNames(
      recipients.map {
        ForLineName(name: $0.user.name, isDeactivated: $0.isDeactivated, link: $0.isLinked ? link($0.id) : nil)
      },
      deactivated: deactivated)
  }

  /// A name on the "For {names}" line: the words of the name, whether "(Deactivated)" follows it, and its link.
  public struct ForLineName: Equatable, Sendable {
    public let name: String
    public let isDeactivated: Bool
    public let link: URL?

    public init(name: String, isDeactivated: Bool, link: URL?) {
      self.name = name
      self.isDeactivated = isDeactivated
      self.link = link
    }
  }

  /// The names on the "For {names}" line, as the locale lists them, each name with its own link.
  public static func forLineNames(_ names: [ForLineName], deactivated: (String) -> String) -> AttributedString {
    // Each name's place is a mark that no name or word holds, so no name needs a search: a short name inside
    // another name, a suffix, or the locale's "and" can't take its link.
    let open: Character = "\u{E000}"
    let close: Character = "\u{E001}"
    let words = names.enumerated().map { index, name in
      let mark = "\(open)\(index)\(close)"
      return name.isDeactivated ? deactivated(mark) : mark
    }
    var rest = Substring(words.formatted(.list(type: .and)))
    var line = AttributedString()
    while let start = rest.firstIndex(of: open), let end = rest[start...].firstIndex(of: close),
      let index = Int(rest[rest.index(after: start)..<end]), names.indices.contains(index)
    {
      line += AttributedString(rest[..<start])
      var name = AttributedString(names[index].name)
      name.link = names[index].link
      line += name
      rest = rest[rest.index(after: end)...]
    }
    line += AttributedString(rest)
    return line
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
    let children = Set(self.user?.record?.childIDs ?? [])
    let isParentOfRecipient = list.recipientIDs.contains { children.contains($0) }
    let noItems: ListPage.NoItems? = items.isEmpty ? (list.canEdit ? .forEditor : .forGiver) : nil
    let leavers = leavers(of: list)
    return ListPage(
      list: list,
      recipients: list.recipientIDs.compactMap { user(id: $0) }.map(ListPage.Recipient.init),
      isRecipient: isRecipient,
      seesWhyItemsAreMissing: !isRecipient && (list.canEdit || isParentOfRecipient),
      items: items,
      noItems: noItems,
      leave: leavers.own,
      makeLeave: leavers.children
    )
  }
}
