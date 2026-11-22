import SwiftUI
import WishboneSession

/// An item's row that opens the item's page, on a list's page and on a user's page. Its context menu has I'll get
/// this for a giver, from `can_claim` while they have no open gift on the item, and Copy link when the item has a
/// store link. VoiceOver offers Open, I'll get this and Copy link as the row's actions. See Actions and
/// Accessibility in `docs/screens/list.md`.
///
/// A claim from the row waits for the server, as on the item's page. A claim that made no gift says why under the
/// row's text, and the result is announced.
struct ItemRowLink: View {
  let item: UserPage.Item

  /// The user whose color the tile takes: the list's first recipient.
  let tileUserID: String
  let session: SessionModel

  /// The window's pages on this tab: the row pushes the item's page.
  @Binding var pages: [Page]

  @State private var isClaiming = false
  @State private var said: String?
  @State private var granted = 0

  var body: some View {
    let copyLink = session.copyLink(ofItem: item.id)
    let offersClaim = session.offersClaim(onItem: item.id) && !isClaiming
    NavigationLink(value: Page.item(id: item.id)) {
      VStack(alignment: .leading, spacing: 4) {
        ItemRowView(item: item, tileUserID: tileUserID)
        if isClaiming {
          Text("Claiming", bundle: #bundle)
        } else if let said {
          Text(said)
        }
      }
      .accessibilityElement(children: .combine)
    }
    .contextMenu {
      if offersClaim {
        claimButton
      }
      if let copyLink {
        CopyLinkButton(url: copyLink)
      }
    }
    .accessibilityAction(named: Text("Open", bundle: #bundle)) {
      pages.append(.item(id: item.id))
    }
    .accessibilityActions {
      if offersClaim {
        claimButton
      }
      if let copyLink {
        CopyLinkButton(url: copyLink)
      }
    }
    .sensoryFeedback(.success, trigger: granted)
  }

  private var claimButton: some View {
    Button {
      Task { await claim() }
    } label: {
      Label {
        Text("I'll get this", bundle: #bundle)
      } icon: {
        Image(systemName: "gift")
      }
    }
  }

  private func claim() async {
    guard !isClaiming else { return }
    isClaiming = true
    said = nil
    let outcome = await session.claim(item: item.id)
    isClaiming = false
    let words: String?
    if outcome == .claimed {
      granted += 1
      words = session.itemPage(id: item.id)?.claims.first.map(ClaimWords.line)
    } else {
      let recipients = session.item(id: item.id).flatMap { session.list(id: $0.listID) }?.recipientIDs ?? []
      said = ClaimWords.result(
        of: outcome, address: session.session.instance, recipients: recipients.compactMap { session.user(id: $0) })
      words = said
    }
    if let words { AccessibilityNotification.Announcement(words).post() }
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
