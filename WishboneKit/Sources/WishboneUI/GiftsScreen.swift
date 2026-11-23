import SwiftUI
import WishboneSession

/// The Gifts tab: a control that picks the part, then the part. Giving is the only part until Given and Received
/// come. Each window has its own part. See `docs/screens/gifts.md`.
///
/// **Giving** has the user's open gifts, in groups by list and occasion. A group with a gift that needs attention
/// goes first, then the groups are in order of reveal. Its states are the ones that every screen shares, and its
/// own empty state.
///
/// **Only the giver sees it.** Nothing from this tab goes to a system surface or into the shared container.
///
/// **Provisional.** Plain default: a segmented control at the top, and each part as a system list in one column of
/// readable width, with a section for each group.
struct GiftsScreen: View {
  let session: SessionModel

  /// The window's part.
  @Binding var part: GiftsPart

  /// The width of the window, for the list's column of readable width.
  @State private var width: CGFloat = 0
  @ScaledMetric(relativeTo: .body) private var readableWidth: CGFloat = 640

  var body: some View {
    let groups = session.givingGroups
    List {
      ForEach(groups) { group in
        Section {
          ForEach(group.gifts) { gift in
            GivingRow(
              gift: gift, tileUserID: group.recipients?.first?.id ?? session.session.userID, session: session)
          }
        } header: {
          GivingHeading(group: group)
        }
      }
    }
    .contentMargins(.horizontal, max(0, (width - readableWidth) / 2), for: .scrollContent)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
    .sharedStates(of: session, hasRows: !groups.isEmpty) {
      GivingIsEmpty()
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      picker
    }
    .navigationTitle(Text("Gifts", bundle: #bundle))
  }

  /// The control that picks the part.
  private var picker: some View {
    Picker(selection: $part) {
      ForEach(GiftsPart.allCases, id: \.self) { part in
        Text(part.name).tag(part)
      }
    } label: {
      Text("Part", bundle: #bundle)
    }
    .pickerStyle(.segmented)
    .padding(.horizontal)
    .padding(.vertical, 8)
    .frame(maxWidth: readableWidth)
    .frame(maxWidth: .infinity)
    // A solid background, so the control has its full contrast over whatever scrolls under it.
    .background(.background, ignoresSafeAreaEdges: [])
  }
}

extension GiftsPart {
  /// The part's name, as the control shows it and VoiceOver reads it.
  var name: String {
    switch self {
    case .giving: String(localized: "Giving", bundle: #bundle)
    }
  }
}

/// A Giving heading: "For Mom and Dad · Christmas", or only the occasion or the reveal date. It is plain text in
/// the primary color, and a heading for the VoiceOver rotor.
private struct GivingHeading: View {
  let group: GivingGroup

  var body: some View {
    Text(GiftWords.heading(group))
      .font(.headline)
      // The absolute primary color: the hierarchical `.primary` takes the header's own secondary style.
      .foregroundStyle(Color.primary)
      .textCase(nil)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityAddTraits(.isHeader)
  }
}

/// A Giving row: the gift, which opens the gift's page, and the bought toggle, from `can_edit`. The toggle is an
/// unsent change, so it works offline, and the row shows it at once. At the largest text sizes, the toggle gets its
/// own line, with its label.
///
/// The gift is one element. Its actions are Open, and Mark bought or Mark not bought. The toggle reads "Bought" and
/// its state.
private struct GivingRow: View {
  let gift: GivingGift

  /// The user whose color the tile takes: the gift's first recipient.
  let tileUserID: String
  let session: SessionModel

  @Environment(\.dynamicTypeSize) private var size

  var body: some View {
    let row = gift.gift
    let isBought = row.isBought.value == true
    let layout =
      size.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
      : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
    layout {
      NavigationLink(value: Page.gift(id: row.id)) {
        GivingGiftLabel(gift: gift, tileUserID: tileUserID)
      }
      .accessibilityActions {
        if row.canEdit {
          Button {
            Task { await session.markBought(gift: row.id, !isBought) }
          } label: {
            Text(GiftWords.markBought(!isBought))
          }
        }
      }
      if row.canEdit {
        BoughtToggle(gift: row, session: session)
          .labelsHidden(!size.isAccessibilitySize)
      }
    }
  }
}

/// The bought toggle of a gift: "Bought", on or off. A change is an unsent change: it shows at once, in every
/// window, and reaches the instance when it can. See "Mark bought" in `docs/screens/gifts.md`.
struct BoughtToggle: View {
  let gift: GiftRow
  let session: SessionModel

  var body: some View {
    Toggle(
      isOn: Binding {
        gift.isBought.value == true
      } set: { isBought in
        Task { await session.markBought(gift: gift.id, isBought) }
      }
    ) {
      Text("Bought", bundle: #bundle)
    }
  }
}

extension View {
  /// Hides the labels of the controls in this view, when `isHidden`. VoiceOver still reads them.
  @ViewBuilder
  fileprivate func labelsHidden(_ isHidden: Bool) -> some View {
    if isHidden { labelsHidden() } else { self }
  }
}

/// The gift of a Giving row: the image, the title, how many when it is more than one, "Hidden until {date}", the from
/// label, bought or not bought, "Needs attention" in words, and each flag in words. It is one element, read in that
/// order, and it opens the gift's page. At the largest text sizes, the image moves above the text.
private struct GivingGiftLabel: View {
  let gift: GivingGift

  /// The user whose color the tile takes: the gift's first recipient.
  let tileUserID: String

  @Environment(\.dynamicTypeSize) private var size

  var body: some View {
    let row = gift.gift
    let layout =
      size.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    layout {
      ItemTile(image: row.image, userID: tileUserID)
      VStack(alignment: .leading, spacing: 2) {
        Text(row.title)
          .font(.body.weight(.semibold))
        if row.quantity > 1 {
          Text(GiftWords.howMany(row.quantity))
        }
        Text(GiftWords.hiddenUntil(row.revealAt))
        if let label = row.fromLabel, !label.isEmpty {
          Text(GiftWords.from(label))
        }
        Text(GiftWords.bought(row.isBought.value == true))
        if gift.needsAttention {
          Label {
            Text(GiftWords.needsAttention)
          } icon: {
            Image(systemName: "exclamationmark.circle")
          }
          .font(.body.weight(.semibold))
        }
        ForEach(Array(gift.flags.enumerated()), id: \.offset) { _, flag in
          Text(GiftWords.flag(flag))
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }
}

/// Giving's empty state: it says so, and points to Home's people. It grows to its words in a scroll view, as the
/// unreachable view does: the unavailable view alone cuts a larger text short.
private struct GivingIsEmpty: View {
  var body: some View {
    GeometryReader { window in
      ScrollView {
        ContentUnavailableView {
          Label {
            Text("You aren't getting anything yet. Open someone on Home and tap I'll get this.", bundle: #bundle)
          } icon: {
            Image(systemName: "gift")
          }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding()
        .frame(maxWidth: .infinity, minHeight: window.size.height)
      }
    }
  }
}
