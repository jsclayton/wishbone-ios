import SwiftUI
import WishboneAPI
import WishboneSession

/// A list's page: the name, the "For {names}" line, the description, the line that says why items can be missing,
/// and the items in the order that Sort sets. See `docs/screens/list.md`.
///
/// Claim state shows only as the server sends it, and the page never says who claimed. Leave, and Make {child}
/// leave, wait for the server. Edit list and Delete list are unsent changes: each shows at once, in every window. A
/// pending invitation to the list, for the user or their child, is at the top, with Accept and Decline.
/// Add item, from `can_edit`, opens the Add screen in a sheet, fixed to the list. Reorder, from `can_edit` and in
/// List order only, is the toolbar's Edit button: the system's edit mode, with handles. Each move is an unsent change.
/// The other actions that change the list or its items come later.
///
/// **Provisional.** Plain default: a system list. The name is the navigation title, the recipients and the
/// description are the first section, and the items are rows with the image at the leading edge. Edit list and Sort
/// are in the toolbar's menu, and Reorder is the toolbar's Edit button. Leave, Make {child} leave and Delete list are
/// destructive rows in the last section, and each confirmation is an alert.
struct ListPageScreen: View {
  let page: ListPage
  let session: SessionModel

  /// The window's pages on this tab: a recipient's name pushes their page.
  @Binding var pages: [Page]

  /// The order of the items. It belongs to this window's page, and is never saved.
  @State private var sort = ListSort.listOrder

  #if os(iOS)
    /// Whether the items show their handles, for Reorder. It ends when Reorder is no longer offered.
    @State private var editMode = EditMode.inactive
  #endif

  /// The window that a refused reorder shows in.
  @Environment(\.foregroundWindow) private var window

  /// The leaver whose confirmation shows.
  @State private var confirming: Leaver?

  /// The leaver whose leave waits for the server.
  @State private var leaving: Leaver?

  /// The words of the last leave that didn't end in a leave.
  @State private var leaveMessage: String?

  /// Whether the Edit list sheet shows.
  @State private var isEditing = false

  /// Whether the confirmation of Delete list shows.
  @State private var isConfirmingDelete = false

  var body: some View {
    List {
      let invitations = session.pendingInvitations(toList: page.list.id)
      if !invitations.isEmpty {
        Section {
          ForEach(invitations) { invitation in
            InvitationView(invitation: invitation, session: session, isOnListPage: true, open: nil)
          }
        }
      }
      Section {
        ForLine(recipients: page.recipients) { pages.append(.user(id: $0)) }
        if let description = page.list.description, !description.allSatisfy(\.isWhitespace) {
          MarkdownView(description)
        }
      }
      Section {
        if page.seesWhyItemsAreMissing {
          // The primary color: the system's secondary gray is below 4.5:1 on the row.
          Text("You see what's been claimed here. Fully claimed items don't show.", bundle: #bundle)
        }
        if let noItems = page.noItems {
          NoItemsLine(noItems: noItems)
        }
        let items = page.items(sortedBy: sort)
        ForEach(items) { item in
          ItemRowLink(item: item, tileUserID: page.list.recipientIDs.first ?? "", session: session, pages: $pages)
        }
        .onMove(perform: offersReorder ? { reorder(items, from: $0, to: $1) } : nil)
        // In edit mode, the system disables the row, so it shows only outside it: edit mode is for Reorder.
        if page.list.canEdit && !isReordering {
          AddItemRow(session: session, listID: page.list.id)
        }
      }
      if page.leave != nil || !page.makeLeave.isEmpty || page.canDelete {
        Section {
          if let leave = page.leave {
            leaveRow(leave)
          }
          ForEach(page.makeLeave) { leaver in
            leaveRow(leaver)
          }
          if let leaveMessage {
            Text(leaveMessage)
          }
          if page.canDelete {
            deleteRow
          }
        }
      }
    }
    .cantReachLine(of: session)
    .sheet(isPresented: $isEditing) {
      EditListSheet(list: page.list, session: session)
    }
    .alert(
      DeleteListWords.title(list: page.list.name), isPresented: $isConfirmingDelete
    ) {
      Button(role: .destructive) {
        Task { await delete() }
      } label: {
        DeleteListWords.action(list: page.list.name)
      }
      Button(role: .cancel) {
      } label: {
        Text("Cancel", bundle: #bundle)
      }
    } message: {
      DeleteListWords.message
    }
    .alert(
      confirming.map { LeaveWords.title(of: $0, list: page.list.name) } ?? Text(String()),
      isPresented: Binding {
        confirming != nil
      } set: {
        if !$0 { confirming = nil }
      },
      presenting: confirming
    ) { leaver in
      Button(role: .destructive) {
        Task { await leave(leaver) }
      } label: {
        LeaveWords.action(of: leaver, list: page.list.name)
      }
      Button(role: .cancel) {
      } label: {
        Text("Cancel", bundle: #bundle)
      }
    } message: { leaver in
      LeaveWords.message(of: leaver)
    }
    .navigationTitle(Text(page.list.name))
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      #if os(iOS)
        if offersReorder {
          ToolbarItem(placement: .primaryAction) {
            EditButton()
          }
        }
      #endif
      ToolbarItem(placement: .primaryAction) {
        Menu {
          if page.list.canEdit {
            Button {
              isEditing = true
            } label: {
              Label {
                Text("Edit list", bundle: #bundle)
              } icon: {
                Image(systemName: "pencil")
              }
            }
          }
          Picker(selection: $sort) {
            ForEach(ListSort.allCases) { sort in
              // The tag is the order itself. The ForEach's own tag is the order's ID, a string, which never matches
              // the selection, so a choice would change nothing.
              SortWords(sort: sort)
                .tag(sort)
            }
          } label: {
            Label {
              Text("Sort", bundle: #bundle)
            } icon: {
              Image(systemName: "arrow.up.arrow.down")
            }
          }
          .pickerStyle(.menu)
        } label: {
          Label {
            Text("More", bundle: #bundle)
          } icon: {
            Image(systemName: "ellipsis")
          }
        }
      }
    }
    #if os(iOS)
      .environment(\.editMode, $editMode)
      .onChange(of: offersReorder) {
        if !offersReorder { editMode = .inactive }
      }
    #endif
  }
}

extension ListPageScreen {
  /// Whether Reorder is offered: the user can edit the list, and it shows in List order.
  private var offersReorder: Bool {
    page.offersReorder(sortedBy: sort)
  }

  /// Whether the items show their handles, for Reorder.
  private var isReordering: Bool {
    #if os(iOS)
      editMode.isEditing
    #else
      false
    #endif
  }

  /// Reorder: the item goes to its new place among the items as they show, as an unsent change. The system's edit
  /// mode moves one item at a time.
  private func reorder(_ items: [UserPage.Item], from source: IndexSet, to destination: Int) {
    guard let index = source.first, items.indices.contains(index) else { return }
    let id = items[index].id
    Task { await session.reorderItem(id, toOffset: destination, from: window) }
  }

  /// A row for Leave, or for Make {child} leave. Its label names the list, and the child. It asks for a
  /// confirmation first.
  private func leaveRow(_ leaver: Leaver) -> some View {
    Button(role: .destructive) {
      leaveMessage = nil
      confirming = leaver
    } label: {
      HStack {
        LeaveWords.row(of: leaver)
        Spacer()
        if leaving == leaver { ProgressView() }
      }
    }
    .disabled(leaving != nil)
    .accessibilityLabel(LeaveWords.action(of: leaver, list: page.list.name))
  }

  /// The Delete list row. Its label reads the action in full. It asks for a confirmation first.
  private var deleteRow: some View {
    Button(role: .destructive) {
      isConfirmingDelete = true
    } label: {
      Text("Delete list", bundle: #bundle)
    }
    .disabled(leaving != nil)
    .accessibilityLabel(DeleteListWords.action(list: page.list.name))
  }

  /// Deletes the list, as an unsent change. It leaves the copy at once, and the page closes in this window, which
  /// shows what was under it. Every other window that shows the page shows the "not found" page.
  private func delete() async {
    let id = page.list.id
    await session.deleteList(id)
    guard session.list(id: id) == nil, let index = pages.lastIndex(of: .list(id: id)) else { return }
    pages.removeSubrange(index...)
  }

  /// Leaves, and waits for the server. After a leave, the page closes in this window, which shows what was under
  /// it. Otherwise the section says why, and nothing changes.
  private func leave(_ leaver: Leaver) async {
    guard leaving == nil else { return }
    leaving = leaver
    leaveMessage = nil
    let list = page.list
    let outcome = await session.leave(list: list.id, as: leaver)
    leaving = nil
    switch outcome {
    case .left:
      if let index = pages.lastIndex(of: .list(id: list.id)) {
        pages.removeSubrange(index...)
      }
    case .unreachable:
      leaveMessage = CantReach.words(for: session.session.instance)
    case .refused(let refusal):
      leaveMessage = LeaveWords.refusal(refusal, of: leaver, list: list.name)
    case .failed:
      leaveMessage = ErrorWords.fault
    }
  }
}

/// The words of Leave, and of Make {child} leave: the row, the confirmation, its button, and a refusal. A button
/// that acts for a child names the child. Nothing here depends on the list's gifts: the only words about claims are
/// the warning, which shows by the server's own rule.
enum LeaveWords {
  /// The row: "Leave", or "Make Emma leave".
  static func row(of leaver: Leaver) -> Text {
    leaver.isSessionUser
      ? Text("Leave", bundle: #bundle) : Text("Make \(leaver.user.name) leave", bundle: #bundle)
  }

  /// What the action does, named in full: "Leave Our house", or "Make Emma leave Our house". The confirmation's
  /// button repeats it, and the row's label reads it.
  static func action(of leaver: Leaver, list: String) -> Text {
    leaver.isSessionUser
      ? Text("Leave \(list)", bundle: #bundle) : Text("Make \(leaver.user.name) leave \(list)", bundle: #bundle)
  }

  /// The confirmation's title.
  static func title(of leaver: Leaver, list: String) -> Text {
    leaver.isSessionUser
      ? Text("Leave \(list)?", bundle: #bundle) : Text("Make \(leaver.user.name) leave \(list)?", bundle: #bundle)
  }

  /// The confirmation's message, with the warning when the leaver will still see the list.
  static func message(of leaver: Leaver) -> Text {
    let name = leaver.user.name
    switch (leaver.isSessionUser, leaver.seesListAfterLeaving) {
    case (true, false):
      return Text("You can be invited again.", bundle: #bundle)
    case (true, true):
      return Text(
        "You can be invited again. You'll see what's been claimed on this list, including gifts for you.",
        bundle: #bundle)
    case (false, false):
      return Text("\(name) can be invited again.", bundle: #bundle)
    case (false, true):
      return Text(
        "\(name) can be invited again. \(name) will see what's been claimed on this list, including gifts for \(name).",
        bundle: #bundle)
    }
  }

  /// The words for a refused leave. `last_recipient` names the list, and `user_deactivated` the child.
  static func refusal(_ refusal: APIError.Refusal, of leaver: Leaver, list: String) -> String {
    switch refusal.code {
    case .lastRecipient: ErrorWords.lastRecipient(of: list)
    case .userDeactivated: ErrorWords.deactivated(leaver.user.name)
    default: ErrorWords.words(for: refusal) ?? ErrorWords.fault
    }
  }
}

/// The words of Delete list: the confirmation, and its button, which the row's label reads too. Nothing here depends
/// on the list's gifts, because that would show a recipient that something is claimed.
enum DeleteListWords {
  /// What the action does, named in full: "Delete Cousins and its items".
  static func action(list: String) -> Text {
    Text("Delete \(list) and its items", bundle: #bundle)
  }

  /// The confirmation's title.
  static func title(list: String) -> Text {
    Text("Delete \(list) and its items?", bundle: #bundle)
  }

  /// The confirmation's message.
  static var message: Text {
    Text("This can't be undone.", bundle: #bundle)
  }
}

/// The words for an order of the Sort menu.
private struct SortWords: View {
  let sort: ListSort

  var body: some View {
    switch sort {
    case .listOrder: Text("List order", bundle: #bundle)
    case .price: Text("Price", bundle: #bundle)
    case .newest: Text("Newest", bundle: #bundle)
    }
  }
}

/// The page's words when the list has no items. For someone who can edit, they point to Add item. The primary color:
/// the system's secondary gray is below 4.5:1 on the row.
private struct NoItemsLine: View {
  let noItems: ListPage.NoItems

  var body: some View {
    Group {
      switch noItems {
      case .forGiver: Text("Nothing on this list yet.", bundle: #bundle)
      case .forEditor: Text("Nothing here yet. Tap Add item to start the list.", bundle: #bundle)
      }
    }
  }
}

/// The "For {names}" line: the recipients' avatars, then "For" and their names. A name links to the user's page
/// only when the session's user sees that user, and "Deactivated" follows it for a viewer who gets it. VoiceOver
/// reads the line as one element, and offers each linked name as a link. A list's page and an item's page show it.
struct ForLine: View {
  let recipients: [ListPage.Recipient]

  /// Opens the page of the user with the ID.
  let open: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !recipients.isEmpty {
        HStack(spacing: -8) {
          ForEach(recipients) { recipient in
            SmallAvatar(user: recipient.user)
          }
        }
      }
      Text("For \(names)", bundle: #bundle)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .environment(
      \.openURL,
      OpenURLAction { url in
        guard let id = RecipientLink.userID(in: url) else { return .discarded }
        open(id)
        return .handled
      })
  }

  /// The names, as the locale lists them, each linked name with its link.
  private var names: AttributedString {
    ListPage.forLineNames(
      of: recipients,
      deactivated: { String(localized: "\($0) (Deactivated)", bundle: #bundle) },
      link: RecipientLink.url(forUserID:))
  }
}

/// A recipient's link on the "For {names}" line. It never leaves the page: the line's own `openURL` takes it.
enum RecipientLink {
  private static let scheme = "wishbone-recipient"

  static func url(forUserID id: String) -> URL? {
    var parts = URLComponents()
    parts.scheme = scheme
    parts.host = "user"
    parts.path = "/\(id)"
    return parts.url
  }

  static func userID(in url: URL) -> String? {
    guard url.scheme == scheme, url.host() == "user" else { return nil }
    let id = String(url.path().dropFirst())
    return id.isEmpty ? nil : id
  }
}

/// A recipient's avatar on the "For {names}" line: small, with a ring that sets it apart from the one under it.
private struct SmallAvatar: View {
  let user: UserRow

  var body: some View {
    PersonAvatar(user: user, size: .small)
      .overlay { Circle().stroke(.background, lineWidth: 2) }
  }
}
