import Foundation
import WishboneAPI

// Home's People: the users whom the session's user gives to, by part. See "Home" in `docs/spec.md`, People in
// `docs/screens/home.md`, and the server spec's "Screens" under "Users and parents".

/// One part of Home's People: Your children, Your parents, or one of the user's groups, with its users.
public struct PeoplePart: Equatable, Sendable, Identifiable {
  public enum Kind: Equatable, Sendable {
    /// Your children.
    case children

    /// Your parents.
    case parents

    /// One of the groups that the session's user is in. `through` is the group that the user is directly in, and
    /// that contains this group by nesting. Nil when the user is directly in this group.
    case group(GroupRow, through: GroupRow?)
  }

  public let kind: Kind

  /// The part's users, in the server's order. Never the session's user.
  public let users: [UserRow]

  public var id: String {
    switch kind {
    case .children: "children"
    case .parents: "parents"
    case .group(let group, _): "group \(group.id)"
    }
  }
}

extension UserRow {
  /// Whether the user is deactivated, as the session's user sees them. Only a viewer who gets the user's
  /// `deactivated_at` sees it: the user, their parents, and the admin. To anyone else, the user is active.
  public var isDeactivated: Bool {
    record?.deactivatedAt.value != nil
  }
}

extension SessionModel {
  /// Home's People, from the copy: "Your children", then "Your parents", then one part for each group that the
  /// session's user is in, directly or through nesting. A part with no users is left out, so a user with nobody to
  /// see gets none.
  ///
  /// - Your children and Your parents are the user's children and parents whom the user sees in full: the ones in
  ///   `GET /users`. So a parent always finds their child here, and a deactivated parent doesn't show to their
  ///   child.
  /// - The groups are only the ones that the user is in, as `GET /groups?includes_me=true` gives them, by name. So
  ///   the admin, who has every group in the copy, gets only their own. A group shows once the copy holds its
  ///   users.
  /// - Each group lists its users, directly or through nesting, in the server's order.
  /// - The user is never among their own people. A user shows once in each part that has them.
  public var people: [PeoplePart] {
    let me = session.userID
    var parts: [PeoplePart] = []

    func seen(_ ids: [String]) -> [UserRow] {
      ids.filter { $0 != me }.compactMap { user(id: $0) }.filter { !$0.isSummary }
    }

    let record = user?.record
    let children = seen(record?.childIDs ?? [])
    if !children.isEmpty { parts.append(PeoplePart(kind: .children, users: children)) }
    let parents = seen(record?.parentIDs ?? [])
    if !parents.isEmpty { parts.append(PeoplePart(kind: .parents, users: parents)) }

    let groupsByID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for group in groups {
      guard let members = members(.usersInGroup, of: group.id), members.contains(me) else { continue }
      let users = seen(members)
      guard !users.isEmpty else { continue }
      let through = group.throughGroupID.flatMap { groupsByID[$0] }
      parts.append(PeoplePart(kind: .group(group, through: through), users: users))
    }
    return parts
  }
}

extension UserRow {
  /// The name with the last name, as the locale writes a full name: "Robin Clark". Only the name when the
  /// session's user gets the user as a summary, or the user has no last name.
  public var fullName: String {
    var name = PersonNameComponents()
    name.givenName = self.name
    name.familyName = record?.lastName.flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 }
    return name.formatted(.name(style: .medium))
  }
}

// The People page: everyone whom the session's user sees, by group. See "People" in `docs/spec.md`, and
// `docs/screens/people.md`.

/// The People page, as everyone sees it: "Your children", then "Your parents", then one part for each of the user's
/// groups. These are the parts of Home's People, in the same order. The admin's parts come later.
public struct PeoplePage: Equatable, Sendable {
  /// The parts, from top to bottom. A part with no users is left out, so a user with nobody to see gets none.
  public let parts: [PeoplePart]

  /// Whether the page has anyone to show. With nobody, the page shows the empty state once a sync has ended.
  public var isEmpty: Bool {
    parts.isEmpty
  }
}

extension SessionModel {
  /// The People page, from the copy. Its parts are Home's People: see `people`.
  public var peoplePage: PeoplePage {
    PeoplePage(parts: people)
  }
}
