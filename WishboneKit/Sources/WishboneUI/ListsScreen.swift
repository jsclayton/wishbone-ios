import SwiftUI
import WishboneSession

/// The Lists tab: every list that the user can edit. "Invitations" first, only while one is pending for the user or
/// their children, each with Accept and Decline. Then "Your lists", the primary list first and then the extra lists
/// by name, then one part for each child, under the child's name, with "Deactivated" beside a deactivated child's
/// name. A tap on a row pushes the list's page, and so does a tap on an invitation's line, when the user can see the
/// list. New list, a toolbar button, opens the New list form in a sheet, and after Save the new list's page is pushed.
/// See `docs/screens/lists.md`.
///
/// Its states are the ones that every screen shares. Every user has a primary list, so the tab is never empty
/// after the first sync.
///
/// **No claim state.** A row's count is the server's `item_count`, with no comment.
///
/// **Provisional.** Plain default: a system list, as Home is, with a section for each part.
struct ListsScreen: View {
  let session: SessionModel

  /// The pages pushed on Lists. A tap on an invitation's line pushes the list's page, and so does Save in the New
  /// list form.
  @Binding var pages: [Page]

  @State private var isMakingList = false

  var body: some View {
    let tab = session.listsTab
    List {
      if !tab.invitations.isEmpty {
        Section {
          ForEach(tab.invitations) { invitation in
            InvitationView(
              invitation: invitation, session: session, isOnListPage: false,
              open: invitation.opensList ? { pages.append(.list(id: invitation.row.listID)) } : nil)
          }
        } header: {
          InvitationsHeading()
        }
      }
      if !tab.yourLists.isEmpty {
        Section {
          rows(tab.yourLists)
        } header: {
          YourListsHeading()
        }
      }
      ForEach(tab.children) { part in
        Section {
          rows(part.lists)
        } header: {
          ChildHeading(child: part.child)
        }
      }
    }
    .sharedStates(of: session, hasRows: !tab.isEmpty) {
      // Every user has a primary list, so the tab is never empty after a sync. It says so anyway.
      ContentUnavailableView {
        Text("No lists yet.", bundle: #bundle)
      }
    }
    .navigationTitle(Text("Lists", bundle: #bundle))
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          isMakingList = true
        } label: {
          Label {
            Text("New list", bundle: #bundle)
          } icon: {
            Image(systemName: "plus")
          }
        }
      }
    }
    .sheet(isPresented: $isMakingList) {
      NewListSheet(session: session) { id in pages.append(.list(id: id)) }
    }
  }

  private func rows(_ lists: [ListRow]) -> some View {
    ForEach(lists) { list in
      NavigationLink(value: Page.list(id: list.id)) {
        ListsRow(list: list, recipients: list.recipientIDs.compactMap { session.user(id: $0) })
      }
    }
  }
}

/// The heading of the user's own lists: "Your lists". It is plain text in the primary color, as Home's part headings
/// are, and a heading for the VoiceOver rotor. A bare `Text` as a section's header takes the system's grey, below
/// 4.5:1, so the heading is in a stack of its own.
private struct YourListsHeading: View {
  var body: some View {
    VStack(alignment: .leading) {
      Text("Your lists", bundle: #bundle)
    }
    .font(.headline)
    .foregroundStyle(.primary)
    .textCase(nil)
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

/// The heading of the invitations: "Invitations". It is plain text in the primary color, as "Your lists" is, and a
/// heading for the VoiceOver rotor.
private struct InvitationsHeading: View {
  var body: some View {
    VStack(alignment: .leading) {
      Text("Invitations", bundle: #bundle)
    }
    .font(.headline)
    .foregroundStyle(.primary)
    .textCase(nil)
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

/// A child's part heading: the child's name, and "Deactivated" beside it when it applies. It is plain text, and a
/// heading for the VoiceOver rotor.
private struct ChildHeading: View {
  let child: UserRow

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(child.name)
        .font(.headline)
        .foregroundStyle(.primary)
      if child.isDeactivated {
        // The primary color, as the count: the secondary color falls short of 4.5:1 at this size.
        Text("Deactivated", bundle: #bundle)
          .font(.subheadline)
      }
    }
    .textCase(nil)
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

/// A list's row on the Lists tab: the name, the recipients' avatars, and how many items the list has, as the server
/// counts them. It is one element: the name, the recipients' names, and the count. At the largest text sizes, the
/// avatars move under the name.
private struct ListsRow: View {
  let list: ListRow
  let recipients: [UserRow]

  @Environment(\.dynamicTypeSize) private var size

  var body: some View {
    Group {
      if size.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 6) {
          name
          avatars
          count
        }
      } else {
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 2) {
            name
            count
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          avatars
        }
      }
    }
    .padding(.vertical, 2)
    // One element, read in the spec's order at every text size: the name, the recipients' names, and the count. The
    // regular layout draws the count before the avatars, so the row gives its own label.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
  }

  /// What VoiceOver reads for the row: the name, the recipients' names, and the count, as the row shows them.
  private var spoken: Text {
    if recipients.isEmpty {
      Text(
        "\(list.name), \(countWords)", bundle: #bundle,
        comment: "A list's row, as VoiceOver reads it: the list's name, then how many items it has")
    } else {
      Text(
        "\(list.name), \(recipients.map(\.name).formatted(.list(type: .and))), \(countWords)", bundle: #bundle,
        comment:
          "A list's row, as VoiceOver reads it: the list's name, the recipients' names, then how many items it has")
    }
  }

  private var name: some View {
    Text(list.name)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var countWords: Text {
    list.itemCount == 0
      ? Text("No items yet", bundle: #bundle) : Text("\(list.itemCount) items", bundle: #bundle)
  }

  private var count: some View {
    countWords
      // The primary color: the secondary color falls short of 4.5:1 at this size, and the accessibility audit fails it.
      .font(.subheadline)
      .fixedSize(horizontal: false, vertical: true)
  }

  /// The recipients' avatars, each over the one before it. The row's label reads the recipients' names in their place.
  @ViewBuilder private var avatars: some View {
    if !recipients.isEmpty {
      HStack(spacing: -8) {
        ForEach(recipients) { recipient in
          PersonAvatar(user: recipient, size: .small)
            .overlay { Circle().stroke(.background, lineWidth: 2) }
        }
      }
    }
  }
}
