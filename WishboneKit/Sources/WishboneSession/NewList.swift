import Foundation
import WishboneAPI

// New list, on the Lists tab: an extra list for the user, or for one of their children. See "A new list for a child"
// and "Unsent changes" in `docs/spec.md`, and `docs/screens/lists.md`.
//
// **Save is an unsent change.** The list shows at once, in every window, by a stand-in ID, and its page is pushed. A
// sync sends it, now or when the instance answers, with its own key, so a resend after a lost answer makes one list.
// Later changes name the list by its stand-in until the server's ID takes its place: an item added to it, an item
// moved to it, and an edit or a delete of it. A refusal takes the list out, with every change that needs it, and
// shows once (see `Journal.swift`).
//
// **Whose list.** A list for a child has the child as its one recipient. The parent who made it is not a recipient:
// they edit it as the child's parent. The form says so.

/// What the New list form holds: the name, the description, and whom the list is for. See "The New list form" in
/// `docs/screens/lists.md`.
public struct NewListDraft: Equatable, Sendable {
  public var name: String

  /// Markdown about the list. Blank is none.
  public var description: String

  /// The list's one recipient, by ID: the session's user, where every form starts, or one of their children.
  public var recipientID: String

  public init(name: String = "", description: String = "", recipientID: String) {
    self.name = name
    self.description = description
    self.recipientID = recipientID
  }

  /// Whether the name has a character that isn't a space. A list can't be without one, so Save waits for it.
  public var hasName: Bool {
    !name.allSatisfy(\.isWhitespace)
  }

  /// Whether the user typed anything, so Cancel asks first.
  public var hasTypedChanges: Bool {
    !name.isEmpty || !description.isEmpty
  }
}

/// A choice of For, in the New list form: the session's user ("You"), or one of their children, by name.
public struct NewListChoice: Equatable, Sendable, Identifiable {
  public let user: UserRow

  /// Whether the choice is the session's user. The form says "You" for them.
  public let isMe: Bool

  public var id: String { user.id }
}

extension SessionModel {
  /// A new form for New list: empty, and for the session's user.
  public func newListDraft() -> NewListDraft {
    NewListDraft(recipientID: session.userID)
  }

  /// The choices of For in the New list form: the session's user first, then each child whose `can_create_list` is
  /// true, in the server's order of the user's children. Empty when no child can have a list made: the form then
  /// has no For, and the list is the user's own. A deactivated child's `can_create_list` is false, and so is that of
  /// a child seen only through the admin's access.
  public var newListChoices: [NewListChoice] {
    guard let me = user else { return [] }
    let children = (me.record?.childIDs ?? []).compactMap { id -> NewListChoice? in
      guard id != me.id, let child = user(id: id), child.record?.canCreateList == true else { return nil }
      return NewListChoice(user: child, isMe: false)
    }
    guard !children.isEmpty else { return [] }
    return [NewListChoice(user: me, isMe: true)] + children
  }

  /// Save, in the New list form: makes the list, as an unsent change. It shows at once in every window, under the
  /// user's own lists or in the child's part, by a stand-in ID, and a sync sends it. The name is trimmed and cut to
  /// the server's limit, and so is the description. A blank description is none.
  ///
  /// It gives the list's stand-in ID, for the page that the form pushes. It does nothing, and gives nil, for a blank
  /// name, and for a recipient that For doesn't offer. It returns when the change is in the journal and published,
  /// and doesn't wait for the sync.
  public func createList(_ draft: NewListDraft) async -> String? {
    guard !hasEnded, let me = user else { return nil }
    let name = String(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.listNameLimit))
    guard !name.isEmpty else { return nil }
    let recipient: UserRow
    if draft.recipientID == me.id {
      recipient = me
    } else if let child = newListChoices.first(where: { !$0.isMe && $0.id == draft.recipientID }) {
      recipient = child.user
    } else {
      return nil
    }
    let trimmed = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
    let description = trimmed.isEmpty ? nil : String(draft.description.prefix(Self.listDescriptionLimit))
    let list = CreatedList(
      id: StandIn.make(), name: name, description: description, recipientID: recipient.id,
      isForAChild: recipient.id != me.id, recipientName: recipient.name, createdAt: .now)
    do {
      try await database.record([LocalDatabase.NewChange(.createList(list), title: name)])
    } catch {
      Log.fault(.session, "The journal can't take an unsent change.", detail: "\(error)")
      return nil
    }
    guard !hasEnded else { return nil }
    await publishNow()
    Task { await syncNow() }
    return list.id
  }
}
