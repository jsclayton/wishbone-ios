import SwiftUI
import WishboneSession

/// An item's row that opens the item's page, on a list's page and on a user's page. Its context menu has I'll get
/// this for a giver, from `can_claim` while they have no open gift on the item, Move to… from the item's `can_edit`
/// when another list can take it, Copy link when the item has a store link, and Edit and Delete from the item's
/// `can_edit` and `can_delete`. VoiceOver offers Open, I'll get this, Move to…, Copy link, Edit and Delete as the
/// row's actions: Move to… is the way to move an item without a drag. See Actions and Accessibility in
/// `docs/screens/list.md`.
///
/// Edit and Move to… open their sheets over the page, and Delete asks first, as on the item's page.
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

  /// Whether the Edit item sheet shows.
  @State private var isEditing = false

  /// Whether the confirmation of Delete shows.
  @State private var isConfirmingDelete = false

  /// Whether the Move to… sheet shows.
  @State private var isMoving = false

  var body: some View {
    let copyLink = session.copyLink(ofItem: item.id)
    let offersClaim = session.offersClaim(onItem: item.id) && !isClaiming
    let row = session.item(id: item.id)
    let offersMove = session.moveTargets(ofItem: item.id) != nil
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
      if offersMove {
        MoveToButton { isMoving = true }
      }
      if let copyLink {
        CopyLinkButton(url: copyLink)
      }
      if row?.canEdit == true {
        editButton
      }
      if row?.canDelete == true {
        deleteButton
      }
    }
    .accessibilityAction(named: Text("Open", bundle: #bundle)) {
      pages.append(.item(id: item.id))
    }
    .accessibilityActions {
      if offersClaim {
        claimButton
      }
      if offersMove {
        MoveToButton { isMoving = true }
      }
      if let copyLink {
        CopyLinkButton(url: copyLink)
      }
      if row?.canEdit == true {
        editButton
      }
      if row?.canDelete == true {
        deleteButton
      }
    }
    .sensoryFeedback(.success, trigger: granted)
    .sheet(isPresented: $isEditing) {
      if let row {
        EditItemSheet(item: row, session: session)
      }
    }
    .sheet(isPresented: $isMoving) {
      MoveToSheet(itemID: item.id, session: session)
    }
    .alert(DeleteItemWords.title(item: item.row.title), isPresented: $isConfirmingDelete) {
      Button(role: .destructive) {
        Task { await session.deleteItem(item.id) }
      } label: {
        DeleteItemWords.action(item: item.row.title)
      }
      Button(role: .cancel) {
      } label: {
        Text("Cancel", bundle: #bundle)
      }
    } message: {
      DeleteItemWords.message
    }
  }

  private var editButton: some View {
    Button {
      isEditing = true
    } label: {
      Label {
        Text("Edit", bundle: #bundle)
      } icon: {
        Image(systemName: "pencil")
      }
    }
  }

  /// Delete: it asks first. Its label reads the action in full.
  private var deleteButton: some View {
    Button(role: .destructive) {
      isConfirmingDelete = true
    } label: {
      Label {
        Text("Delete", bundle: #bundle)
      } icon: {
        Image(systemName: "trash")
      }
    }
    .accessibilityLabel(DeleteItemWords.action(item: item.row.title))
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
