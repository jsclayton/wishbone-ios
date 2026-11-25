import SwiftUI
import WishboneSession

/// A given gift's page: the image, title and price as they were at reveal, who gave it, who it was for, the
/// occasion, how many, and the date it was given. Its giver also sees the bought mark and the note, as they were.
/// See "A given gift" in `docs/screens/gift.md`.
///
/// From `can_restore`, I didn't get this sits at the foot, after a confirmation. It waits for the server. After it,
/// the gift leaves the copy, and the page closes in this window, which shows what was under it. Otherwise the row
/// says why, in place, and nothing changes.
///
/// **A recipient never sees the giver's note or bought mark.** The server doesn't send them, and the page shows them
/// only to the giver. The page never says who else claimed the item. Nothing on it goes to a system surface or into
/// the shared container.
///
/// **Provisional.** Plain default: a system list in one column of readable width. The image and title are the
/// header, and each field is a row.
struct GivenGiftPageScreen: View {
  let page: GivenGiftPage
  let session: SessionModel

  /// The window's pages on the tab, so that I didn't get this closes this page.
  @Binding var pages: [Page]

  /// What I didn't get this asks about.
  @State private var confirmingRestore: RestoreAsk?

  /// Whether a restore waits for the server.
  @State private var isRestoring = false

  /// The words of the last restore that didn't happen.
  @State private var restoreSaid: String?

  /// The width of the window, for the list's column of readable width.
  @State private var width: CGFloat = 0
  @ScaledMetric(relativeTo: .body) private var readableWidth: CGFloat = 640

  var body: some View {
    let gift = page.gift
    let tileUserID = page.recipients?.first?.id ?? gift.giverID ?? ""
    List {
      Section {
        if page.linksItem {
          NavigationLink(value: Page.item(id: gift.itemID)) {
            GiftHeader(gift: gift, tileUserID: tileUserID)
          }
        } else {
          GiftHeader(gift: gift, tileUserID: tileUserID)
        }
        Text(GiftWords.givenBy(fromLabel: gift.fromLabel, giver: page.giverName))
        if page.linksList {
          NavigationLink(value: Page.list(id: gift.listID)) {
            Text(gift.listName)
          }
        } else {
          Text(gift.listName)
        }
        if let recipients = page.recipients, !recipients.isEmpty {
          Text(GiftWords.forLine(recipients.map(\.name)))
        }
      }
      Section {
        FieldRow(label: String(localized: "Occasion", bundle: #bundle)) {
          VStack(alignment: .trailing, spacing: 2) {
            if let name = gift.occasionName, !name.isEmpty {
              Text(name)
            }
            Text(OccasionDateWords.withYear(gift.occasionDate))
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
        FieldRow(label: String(localized: "How many", bundle: #bundle)) {
          Text(gift.quantity.formatted())
        }
        if let givenAt = gift.givenAt {
          FieldRow(label: String(localized: "Given", bundle: #bundle)) {
            Text(givenAt.formatted(.dateTime.month(.abbreviated).day().year()))
          }
        }
      }
      if page.isGiver {
        Section {
          FieldRow(label: String(localized: "Bought", bundle: #bundle)) {
            Text(
              gift.isBought.value == true
                ? String(localized: "Yes", bundle: #bundle) : String(localized: "No", bundle: #bundle))
          }
          FieldRow(label: String(localized: "Note", bundle: #bundle)) {
            if let note = gift.note.value, !note.isEmpty {
              Text(note)
            }
          }
        } footer: {
          Text("Only you see this note.", bundle: #bundle)
        }
      }
      if let restorer = page.restorer {
        Section {
          Button(role: .destructive) {
            restoreSaid = nil
            confirmingRestore = RestoreAsk(gift: gift, restorer: restorer)
          } label: {
            HStack(spacing: 8) {
              if isRestoring {
                ProgressView()
                  .accessibilityHidden(true)
              }
              Text(RestoreWords.action(of: restorer))
            }
            .frame(maxWidth: .infinity)
          }
          .disabled(isRestoring)
          if let restoreSaid {
            Text(restoreSaid)
          }
        }
      }
    }
    .didntGetThisConfirmation(of: $confirmingRestore) { ask in
      Task { await restore(ask) }
    }
    .contentMargins(.horizontal, max(0, (width - readableWidth) / 2), for: .scrollContent)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
    .cantReachLine(of: session)
    .navigationTitle(Text("Gift", bundle: #bundle))
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }

  /// I didn't get this: waits for the server. After a restore, the page closes in this window, which shows what was
  /// under it. Otherwise the row says why, and nothing changes.
  private func restore(_ ask: RestoreAsk) async {
    guard !isRestoring else { return }
    isRestoring = true
    restoreSaid = nil
    let outcome = await session.restore(gift: ask.gift.id)
    isRestoring = false
    if outcome == .restored, let index = pages.lastIndex(of: .gift(id: ask.gift.id)) {
      pages.removeSubrange(index...)
    }
    restoreSaid = RestoreWords.result(of: outcome, address: session.session.instance)
    if let restoreSaid { AccessibilityNotification.Announcement(restoreSaid).post() }
  }
}
