import SwiftUI
import WishboneSession

/// A gift's page, for an open gift, as its giver reads it: the item's image, title and price, the list, who the gift
/// is for, each flag in words with every change of a changed item, then Bought, How many, Occasion with the reveal
/// date, From, and Note. See `docs/screens/gift.md`.
///
/// Bought is a toggle, from `can_edit`: an unsent change. The other fields are read here. Each becomes a control, and
/// each flag gets its answer, in a later step.
///
/// **Only its giver sees an open gift,** and the page never says who else claimed the item. Nothing on it goes to a
/// system surface or into the shared container.
///
/// **Provisional.** Plain default: a system list in one column of readable width. The image and title are the
/// header, the flags are the first section, and each field is a row.
struct GiftPageScreen: View {
  let page: GiftPage
  let session: SessionModel

  /// The width of the window, for the list's column of readable width.
  @State private var width: CGFloat = 0
  @ScaledMetric(relativeTo: .body) private var readableWidth: CGFloat = 640

  var body: some View {
    let gift = page.gift
    List {
      Section {
        if page.linksItem {
          NavigationLink(value: Page.item(id: gift.itemID)) {
            GiftHeader(page: page)
          }
        } else {
          GiftHeader(page: page)
        }
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
      if !page.flags.isEmpty {
        Section {
          ForEach(Array(page.flags.enumerated()), id: \.offset) { _, flag in
            FlagRow(flag: flag, changes: page.changes)
          }
        }
      }
      Section {
        if gift.canEdit {
          // An unsent change: it shows at once, and reaches the instance when it can.
          BoughtToggle(gift: gift, session: session)
        } else {
          FieldRow(label: String(localized: "Bought", bundle: #bundle)) {
            Text(
              gift.isBought.value == true
                ? String(localized: "Yes", bundle: #bundle) : String(localized: "No", bundle: #bundle))
          }
        }
        if gift.canEdit {
          FieldRow(label: String(localized: "How many", bundle: #bundle)) {
            Text(gift.quantity.formatted())
          }
        }
        FieldRow(label: String(localized: "Occasion", bundle: #bundle)) {
          VStack(alignment: .trailing, spacing: 2) {
            Text(GiftWords.occasion(page.occasion))
            if case .named = page.occasion {
              Text(GiftWords.hiddenUntil(gift.revealAt))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
          }
        }
        FieldRow(label: String(localized: "From", bundle: #bundle)) {
          if let label = gift.fromLabel, !label.isEmpty {
            Text(label)
          } else {
            Text("Who it's from, if not only you", bundle: #bundle)
              .foregroundStyle(.secondary)
          }
        }
      }
      Section {
        FieldRow(label: String(localized: "Note", bundle: #bundle)) {
          if let note = gift.note.value, !note.isEmpty {
            Text(note)
          }
        }
      } footer: {
        Text("Only you see this note.", bundle: #bundle)
      }
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
}

/// The header: the item's image, its title as large text, and its price, as they are now, or as they were when the
/// item was removed. At the largest text sizes, the image moves above the text.
private struct GiftHeader: View {
  let page: GiftPage

  @Environment(\.dynamicTypeSize) private var size

  var body: some View {
    let gift = page.gift
    let layout =
      size.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    layout {
      ItemTile(image: gift.image, userID: page.recipients?.first?.id ?? gift.giverID ?? "")
      VStack(alignment: .leading, spacing: 4) {
        Text(gift.title)
          .font(.title2.weight(.bold))
          .accessibilityAddTraits(.isHeader)
        if let price = PriceWords.page(
          priceMinor: gift.priceMinor, topPriceMinor: gift.topPriceMinor, currency: gift.currency)
        {
          Text(price)
            .font(.title3)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 4)
  }
}

/// A flag, in words. A changed item lists each change under it, old to new. The flag and its changes are one
/// element.
private struct FlagRow: View {
  let flag: GivingGift.Flag
  let changes: [GiftPage.Change]

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label {
        Text(GiftWords.pageFlag(flag))
          .font(.body.weight(.semibold))
      } icon: {
        Image(systemName: "exclamationmark.circle")
      }
      if flag == .changed {
        ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
          Text(GiftWords.change(change))
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .combine)
  }
}

/// A field: its label, and its value at the trailing edge. At the largest text sizes, the label sits above the
/// value. The row is one element.
private struct FieldRow<Value: View>: View {
  let label: String
  @ViewBuilder let value: Value

  @Environment(\.dynamicTypeSize) private var size

  var body: some View {
    Group {
      if size.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 4) {
          Text(label)
            .foregroundStyle(.secondary)
          value
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        HStack(alignment: .firstTextBaseline) {
          Text(label)
          Spacer(minLength: 16)
          value
            .multilineTextAlignment(.trailing)
            .foregroundStyle(.secondary)
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .combine)
  }
}
