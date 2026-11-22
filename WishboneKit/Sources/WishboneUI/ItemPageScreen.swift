import SwiftUI
import WishboneAPI
import WishboneSession

/// An item's page: the images, the title and the price, the list and its recipients, how many are still wanted or
/// wanted, the notes, the store links, and "Added by {name}". See `docs/screens/item.md`.
///
/// Claim state shows only as the server sends it, and the page never says who else claimed. I'll get this and the
/// edit controls come later.
///
/// **Provisional.** Plain default: a system list, one column at every size. The images are a row that pages
/// sideways, the title is large text under it, and each part is a section. Copy link is in the toolbar's menu.
struct ItemPageScreen: View {
  let page: ItemPage
  let session: SessionModel

  /// The window's pages on this tab: the list's name and a name push their pages.
  @Binding var pages: [Page]

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
      if page.stillWanted != nil || page.wanted != nil {
        Section {
          if let stillWanted = page.stillWanted {
            StillWantedLine(stillWanted: stillWanted)
          }
          if let wanted = page.wanted {
            WantedLine(wanted: wanted)
          }
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
    }
    .cantReachLine(of: session)
    .navigationTitle(Text(page.item.title))
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      if let copyLink = page.copyLink {
        ToolbarItem(placement: .primaryAction) {
          Menu {
            CopyLinkButton(url: copyLink)
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

/// The images, in a row that pages sideways, the primary image first. With none, a tile in the recipient's person
/// color. VoiceOver reads it as one adjustable element, "Photo {n} of {m}".
private struct ImagePager: View {
  let images: [ImageSummary]
  let tileUserID: String

  @State private var shown = 0
  @ScaledMetric(relativeTo: .body) private var height: CGFloat = 280

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
    .frame(height: min(height, 420))
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
          .foregroundStyle(.secondary)
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
              .foregroundStyle(.secondary)
          }
          .fixedSize(horizontal: false, vertical: true)
          // The arrow's words follow the row's, so VoiceOver reads "{store}, {price}, opens in browser".
          Image(systemName: "arrow.up.right")
            .foregroundStyle(.secondary)
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
