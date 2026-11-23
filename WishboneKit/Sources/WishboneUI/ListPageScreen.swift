import SwiftUI
import WishboneAPI
import WishboneSession

/// A list's page: the name, the "For {names}" line, the description, the line that says why items can be missing,
/// and the items in the order that Sort sets. See `docs/screens/list.md`.
///
/// Claim state shows only as the server sends it, and the page never says who claimed. Leave, and Make {child}
/// leave, wait for the server. The other actions that change the list or its items come later.
///
/// **Provisional.** Plain default: a system list. The name is the navigation title, the recipients and the
/// description are the first section, and the items are rows with the image at the leading edge. Sort is in the
/// toolbar's menu.
struct ListPageScreen: View {
  let page: ListPage
  let session: SessionModel

  /// The window's pages on this tab: a recipient's name pushes their page.
  @Binding var pages: [Page]

  /// The order of the items. It belongs to this window's page, and is never saved.
  @State private var sort = ListSort.listOrder

  /// The leaver whose confirmation shows.
  @State private var confirming: Leaver?

  /// The leaver whose leave waits for the server.
  @State private var leaving: Leaver?

  /// The words of the last leave that didn't end in a leave.
  @State private var leaveMessage: String?

  var body: some View {
    List {
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
        ForEach(page.items(sortedBy: sort)) { item in
          ItemRowLink(item: item, tileUserID: page.list.recipientIDs.first ?? "", session: session, pages: $pages)
        }
      }
      if page.leave != nil || !page.makeLeave.isEmpty {
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
        }
      }
    }
    .cantReachLine(of: session)
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
      ToolbarItem(placement: .primaryAction) {
        Menu {
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
  }
}

extension ListPageScreen {
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
