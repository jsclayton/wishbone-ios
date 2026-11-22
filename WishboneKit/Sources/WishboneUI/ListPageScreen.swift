import SwiftUI
import WishboneAPI
import WishboneSession

/// A list's page: the name, the "For {names}" line, the description, the line that says why items can be missing,
/// and the items in the order that Sort sets. See `docs/screens/list.md`.
///
/// Claim state shows only as the server sends it, and the page never says who claimed. Every action that changes
/// the list or its items comes later.
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
          Text("You see what's been claimed here. Fully claimed items don't show.", bundle: #bundle)
            .foregroundStyle(.secondary)
        }
        if let noItems = page.noItems {
          NoItemsLine(noItems: noItems)
        }
        ForEach(page.items(sortedBy: sort)) { item in
          ItemRowLink(item: item, tileUserID: page.list.recipientIDs.first ?? "", session: session, pages: $pages)
        }
      }
    }
    .cantReachLine(of: session)
    .navigationTitle(Text(page.list.name))
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          Picker(selection: $sort) {
            ForEach(ListSort.allCases) { sort in
              SortWords(sort: sort)
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

/// The page's words when the list has no items. For someone who can edit, they point to Add item.
private struct NoItemsLine: View {
  let noItems: ListPage.NoItems

  var body: some View {
    Group {
      switch noItems {
      case .forGiver: Text("Nothing on this list yet.", bundle: #bundle)
      case .forEditor: Text("Nothing here yet. Tap Add item to start the list.", bundle: #bundle)
      }
    }
    .foregroundStyle(.secondary)
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
