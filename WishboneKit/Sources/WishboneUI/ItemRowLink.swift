import SwiftUI
import WishboneSession

/// An item's row that opens the item's page, on a list's page and on a user's page. Its context menu has Copy link
/// when the item has a store link. VoiceOver offers Open and Copy link as the row's actions. See Actions and
/// Accessibility in `docs/screens/list.md`.
struct ItemRowLink: View {
  let item: UserPage.Item

  /// The user whose color the tile takes: the list's first recipient.
  let tileUserID: String
  let session: SessionModel

  /// The window's pages on this tab: the row pushes the item's page.
  @Binding var pages: [Page]

  var body: some View {
    let copyLink = session.copyLink(ofItem: item.id)
    NavigationLink(value: Page.item(id: item.id)) {
      ItemRowView(item: item, tileUserID: tileUserID)
    }
    .contextMenu {
      if let copyLink {
        CopyLinkButton(url: copyLink)
      }
    }
    .accessibilityAction(named: Text("Open", bundle: #bundle)) {
      pages.append(.item(id: item.id))
    }
    .accessibilityActions {
      if let copyLink {
        CopyLinkButton(url: copyLink)
      }
    }
  }
}

/// Copy link: it copies an item's first store link, and nothing else.
struct CopyLinkButton: View {
  let url: URL

  var body: some View {
    Button {
      Pasteboard.copy(url)
    } label: {
      Label {
        Text("Copy link", bundle: #bundle)
      } icon: {
        Image(systemName: "link")
      }
    }
  }
}
