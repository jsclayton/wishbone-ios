import SwiftUI
import WishboneAPI
import WishboneSession

/// An item's page: the images, the title and the price, the list and its recipients, how many are still wanted or
/// wanted, the notes, the store links, and "Added by {name}". See `docs/screens/item.md`.
///
/// Claim state shows only as the server sends it, and the page never says who else claimed. For a giver, I'll get
/// this claims one at once, and waits for the server: see `ClaimSection`. For a user who can edit, Edit opens the
/// Edit item sheet, and Delete asks first. Each is an unsent change: it shows at once, in every window. After a
/// delete, the page closes in this window, and any other window that shows it shows the "not found" page.
///
/// **Provisional.** Plain default: a system list, one column at every size. The images are a row that pages
/// sideways, the title is large text under it, and each part is a section. Edit is a toolbar button, and Copy link
/// and Delete are in the toolbar's menu. The Delete confirmation is an alert.
struct ItemPageScreen: View {
  let page: ItemPage
  let session: SessionModel

  /// The window's pages on this tab: the list's name and a name push their pages.
  @Binding var pages: [Page]

  /// Whether the Edit item sheet shows.
  @State private var isEditing = false

  /// Whether the confirmation of Delete shows.
  @State private var isConfirmingDelete = false

  var body: some View {
    List {
      Section {
        ImagePager(images: page.images, tileUserID: page.list.recipientIDs.first ?? "")
          .listRowInsets(EdgeInsets())
        TitleAndPrice(item: page.item)
      }
      Section {
        NavigationLink(value: Page.list(id: page.list.id)) {
          Text(page.list.name)
        }
        ForLine(recipients: page.recipients) { pages.append(.user(id: $0)) }
      }
      if let stillWanted = page.stillWanted {
        Section {
          StillWantedLine(stillWanted: stillWanted)
          ClaimSection(page: page, session: session)
        }
      }
      if let notes = page.item.notes, !notes.allSatisfy(\.isWhitespace) {
        Section {
          Text(notes)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if !page.storeLinks.isEmpty {
        Section {
          ForEach(page.storeLinks) { link in
            StoreLinkLine(link: link)
          }
        }
      }
      if let addedBy = page.addedBy {
        Section {
          AddedByLine(user: addedBy)
        }
      }
      // For a user who can edit: how many are wanted, after "Added by", as the screen's spec orders it.
      if let wanted = page.wanted {
        Section {
          WantedLine(wanted: wanted)
        }
      }
    }
    .cantReachLine(of: session)
    .sheet(isPresented: $isEditing) {
      EditItemSheet(item: page.item, session: session)
    }
    .alert(DeleteItemWords.title(item: page.item.title), isPresented: $isConfirmingDelete) {
      Button(role: .destructive) {
        Task { await delete() }
      } label: {
        DeleteItemWords.action(item: page.item.title)
      }
      Button(role: .cancel) {
      } label: {
        Text("Cancel", bundle: #bundle)
      }
    } message: {
      DeleteItemWords.message
    }
    .navigationTitle(Text(page.item.title))
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      if page.item.canEdit {
        ToolbarItem(placement: .primaryAction) {
          Button {
            isEditing = true
          } label: {
            Text("Edit", bundle: #bundle)
          }
        }
      }
      if page.copyLink != nil || page.item.canDelete {
        ToolbarItem(placement: .primaryAction) {
          Menu {
            if let copyLink = page.copyLink {
              CopyLinkButton(url: copyLink)
            }
            if page.item.canDelete {
              Button(role: .destructive) {
                isConfirmingDelete = true
              } label: {
                Label {
                  Text("Delete", bundle: #bundle)
                } icon: {
                  Image(systemName: "trash")
                }
              }
              .accessibilityLabel(DeleteItemWords.action(item: page.item.title))
            }
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
}

extension ItemPageScreen {
  /// Deletes the item, as an unsent change. It leaves the copy at once, and the page closes in this window, which
  /// shows what was under it. Every other window that shows the page shows the "not found" page.
  private func delete() async {
    let id = page.item.id
    await session.deleteItem(id)
    guard session.item(id: id) == nil,
      let index = pages.lastIndex(where: { shown in
        if case .item(let shownID) = shown { session.serverID(of: shownID) == id } else { false }
      })
    else { return }
    pages.removeSubrange(index...)
  }
}

/// The words of Delete, on an item's page and in its row's context menu: the confirmation, and its button, which the
/// menu item's label reads too. Nothing here depends on the item's gifts, because that would show a recipient that
/// something is claimed.
enum DeleteItemWords {
  /// What the action does, named in full: "Delete Kite".
  static func action(item: String) -> Text {
    Text("Delete \(item)", bundle: #bundle)
  }

  /// The confirmation's title.
  static func title(item: String) -> Text {
    Text("Delete \(item)?", bundle: #bundle)
  }

  /// The confirmation's message.
  static var message: Text {
    Text("This can't be undone.", bundle: #bundle)
  }
}

/// The images, in a row that pages sideways, the primary image first. With none, a tile in the recipient's person
/// color. VoiceOver reads it as one adjustable element, "Photo {n} of {m}".
private struct ImagePager: View {
  let images: [ImageSummary]
  let tileUserID: String

  @State private var shown = 0
  /// The row's height. A photo doesn't grow with the text size, so at the largest sizes the item's words still
  /// come soon after it.
  private let height: CGFloat = 200

  var body: some View {
    Group {
      if images.isEmpty {
        tile
          .accessibilityHidden(true)
      } else {
        pager
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(Text("Photo \(shown + 1) of \(images.count)", bundle: #bundle))
          .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: shown = min(shown + 1, images.count - 1)
            case .decrement: shown = max(shown - 1, 0)
            @unknown default: break
            }
          }
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: height)
    // A sync can take images away while the page shows: the shown photo stays one that the item still has.
    .onChange(of: images.count) {
      shown = min(shown, max(images.count - 1, 0))
    }
  }

  private var pager: some View {
    TabView(selection: $shown) {
      ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
        SessionImage(image: image) { tile }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .clipped()
          .tag(index)
      }
    }
    #if os(iOS)
      .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .always : .never))
    #endif
  }

  /// The tile, while there is no image.
  private var tile: some View {
    let color = PersonPalette.color(forUserID: tileUserID)
    return Rectangle()
      .fill(color.opacity(0.15))
      .overlay {
        Image(systemName: "gift")
          .font(.system(size: 64))
          .foregroundStyle(color)
      }
  }
}

/// The title as large text, and the price or the range under it.
private struct TitleAndPrice: View {
  let item: ItemRow

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(item.title)
        .font(.title2.weight(.bold))
        .accessibilityAddTraits(.isHeader)
      if let price = PriceWords.page(
        priceMinor: item.priceMinor, topPriceMinor: item.topPriceMinor, currency: item.currency)
      {
        Text(price)
          .font(.title3)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .padding(.vertical, 4)
  }
}

/// For a giver: "{n} of {m} still wanted", or "Always wanted".
private struct StillWantedLine: View {
  let stillWanted: ItemPage.StillWanted

  var body: some View {
    switch stillWanted {
    case .count(let count, let quantity): Text("\(count) of \(quantity) still wanted", bundle: #bundle)
    case .always: Text("Always wanted", bundle: #bundle)
    }
  }
}

/// For a giver: one line for each of their own open gifts on the item, which opens the gift's page, or else I'll get
/// this, and what the last
/// claim said in place. The button waits for the server's answer, and says "Claiming" while it waits. A claim that
/// the server grants plays the system's success haptic, and the result is announced. See `docs/screens/item.md`.
///
/// **Provisional.** Plain default: the lines and the button are rows of the section, under how many are still
/// wanted.
private struct ClaimSection: View {
  let page: ItemPage
  let session: SessionModel

  @State private var isClaiming = false
  @State private var result: Result?
  @State private var granted = 0

  /// What the last claim said, in place, and whether the button stays beside it.
  private struct Result: Equatable {
    let words: String
    /// Someone else got the last one: the words take the button's place.
    let replacesButton: Bool
  }

  var body: some View {
    Group {
      ForEach(page.claims) { claim in
        // The line opens the gift's page.
        NavigationLink(value: Page.gift(id: claim.id)) {
          Text(ClaimWords.line(claim))
            .font(.body.weight(.semibold))
        }
      }
      if page.claims.isEmpty {
        if page.offersClaim, result?.replacesButton != true {
          claimButton
        }
        if let result {
          Text(result.words)
        }
      }
    }
    .sensoryFeedback(.success, trigger: granted)
    // A new item in the same window starts with nothing said.
    .onChange(of: page.item.id) {
      result = nil
    }
  }

  private var claimButton: some View {
    Button {
      Task { await claim() }
    } label: {
      if isClaiming {
        HStack(spacing: 8) {
          ProgressView()
          Text("Claiming", bundle: #bundle)
        }
      } else {
        Text("I'll get this", bundle: #bundle)
      }
    }
    .disabled(isClaiming)
  }

  private func claim() async {
    guard !isClaiming else { return }
    isClaiming = true
    result = nil
    let id = page.item.id
    let outcome = await session.claim(item: id)
    isClaiming = false
    let words: String?
    if outcome == .claimed {
      granted += 1
      words = session.itemPage(id: id)?.claims.first.map(ClaimWords.line)
    } else {
      let said = ClaimWords.result(
        of: outcome, address: session.session.instance, recipients: page.recipients.map(\.user))
      result = said.map { Result(words: $0, replacesButton: outcome == .someoneElseGotIt) }
      words = said
    }
    if let words { AccessibilityNotification.Announcement(words).post() }
  }
}

/// For a user who can edit: "Wants {n}", or "Always wanted".
private struct WantedLine: View {
  let wanted: ItemPage.Wanted

  var body: some View {
    switch wanted {
    case .count(let count): Text("Wants \(count)", bundle: #bundle)
    case .always: Text("Always wanted", bundle: #bundle)
    }
  }
}

/// A store link: its store, then its price and when the price was read, or "no price". A tap opens the store's page
/// in the default browser. VoiceOver reads the store, the price, and "opens in browser". At the largest text sizes,
/// the price moves under the store's name.
private struct StoreLinkLine: View {
  let link: StoreLinkRow

  @Environment(\.dynamicTypeSize) private var size

  var body: some View {
    if let url = URL(string: link.url) {
      // The system opens a web address in the default browser.
      Link(destination: url) {
        HStack {
          let layout =
            size.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 8))
          layout {
            Text(link.store)
              .foregroundStyle(.primary)
            if !size.isAccessibilitySize { Spacer(minLength: 0) }
            detail
          }
          .fixedSize(horizontal: false, vertical: true)
          // The arrow's words follow the row's, so VoiceOver reads "{store}, {price}, opens in browser".
          Image(systemName: "arrow.up.right")
            .accessibilityLabel(Text("opens in browser", bundle: #bundle))
        }
        .contentShape(.rect)
      }
      .accessibilityElement(children: .combine)
      .accessibilityInputLabels([Text(link.store)])
    }
  }

  /// The price and when it was read, "$24.99 · read Nov 3", or "no price".
  private var detail: Text {
    guard let price = PriceWords.storeLink(priceMinor: link.priceMinor, currency: link.currency) else {
      return Text("no price", bundle: #bundle)
    }
    guard let read = link.capturedAt else { return Text(price) }
    let day = read.formatted(.dateTime.month(.abbreviated).day())
    return Text("\(price) · read \(day)", bundle: #bundle)
  }
}

/// "Added by {name}". The name pushes the user's page, when the session's user sees that user.
private struct AddedByLine: View {
  let user: UserRow

  var body: some View {
    if user.isSummary {
      Text("Added by \(user.name)", bundle: #bundle)
    } else {
      NavigationLink(value: Page.user(id: user.id)) {
        Text("Added by \(user.name)", bundle: #bundle)
      }
    }
  }
}
