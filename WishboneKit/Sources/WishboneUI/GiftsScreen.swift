import SwiftUI
import WishboneSession

/// The Gifts tab: a control that picks the part, then the part. Each window has its own part. See
/// `docs/screens/gifts.md`.
///
/// **Giving** has the user's open gifts, in groups by list and occasion. A group with a gift that needs attention
/// goes first, then the groups are in order of reveal. **Given** has the gifts that the user gave, and **Received**
/// the gifts given to the user, not to their children. Each is in groups by occasion, the newest first. Each part's
/// states are the ones that every screen shares, and its own empty state.
///
/// **Only the giver sees Giving and Given.** Received has no giver's note or bought mark: the server doesn't send
/// them. Nothing from this tab goes to a system surface or into the shared container.
///
/// **Provisional.** Plain default: a segmented control at the top, and each part as a system list in one column of
/// readable width, with a section for each group.
struct GiftsScreen: View {
  let session: SessionModel

  /// The window's part.
  @Binding var part: GiftsPart

  /// The gift that I won't get this asks about.
  @State private var confirmingUnclaim: GiftRow?

  /// The gift that I didn't get this asks about.
  @State private var confirmingRestore: RestoreAsk?

  /// The words of the last I didn't get this that didn't happen, in an alert.
  @State private var restoreSaid: String?

  /// The add form that Add again opened, in its sheet.
  @State private var addingAgain: AddAgainForm?

  /// The width of the window, for the list's column of readable width.
  @State private var width: CGFloat = 0
  @ScaledMetric(relativeTo: .body) private var readableWidth: CGFloat = 640

  var body: some View {
    content
      .contentMargins(.horizontal, max(0, (width - readableWidth) / 2), for: .scrollContent)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: {
        width = $0
      }
      .safeAreaInset(edge: .top, spacing: 0) {
        picker
      }
      .navigationTitle(Text("Gifts", bundle: #bundle))
  }

  @ViewBuilder
  private var content: some View {
    switch part {
    case .giving: giving
    case .given: given
    case .received: received
    }
  }

  private var giving: some View {
    let groups = session.givingGroups
    return List {
      ForEach(groups) { group in
        Section {
          ForEach(group.gifts) { gift in
            GivingRow(
              gift: gift, tileUserID: group.recipients?.first?.id ?? session.session.userID, session: session,
              wontGetThis: { confirmingUnclaim = gift.gift })
          }
        } header: {
          GiftsHeading(words: GiftWords.heading(group))
        }
      }
    }
    .wontGetThisConfirmation(of: $confirmingUnclaim) { gift in
      Task { await session.unclaim(gift: gift.id) }
    }
    .sharedStates(of: session, hasRows: !groups.isEmpty) {
      PartIsEmpty(
        words: String(
          localized: "You aren't getting anything yet. Open someone on Home and tap I'll get this.", bundle: #bundle))
    }
  }

  private var given: some View {
    let groups = session.givenGroups
    return List {
      ForEach(groups) { group in
        Section {
          ForEach(group.gifts) { row in
            NavigationLink(value: Page.gift(id: row.id)) {
              GivenLabel(row: row)
            }
          }
        } header: {
          GiftsHeading(words: GiftWords.heading(group))
        }
      }
    }
    .sharedStates(of: session, hasRows: !groups.isEmpty) {
      PartIsEmpty(
        words: String(localized: "Nothing given yet. A gift moves here the day after its occasion.", bundle: #bundle))
    }
  }

  private var received: some View {
    let groups = session.receivedGroups
    return List {
      ForEach(groups) { group in
        Section {
          ForEach(group.gifts) { row in
            ReceivedRow(
              row: row, tileUserID: session.session.userID,
              didntGetThis: { confirmingRestore = RestoreAsk(gift: row.gift, restorer: .sessionUser) },
              addAgain: { addingAgain = session.addAgainForm(gift: row.id).map { AddAgainForm(draft: $0) } })
          }
        } header: {
          GiftsHeading(words: GiftWords.heading(group))
        }
      }
    }
    .didntGetThisConfirmation(of: $confirmingRestore) { ask in
      Task { await restore(ask) }
    }
    .addAgainSheet($addingAgain, session: session)
    .alert(
      restoreSaid ?? "",
      isPresented: Binding {
        restoreSaid != nil
      } set: {
        if !$0 { restoreSaid = nil }
      }
    ) {
      Button(role: .cancel) {
      } label: {
        Text("OK", bundle: #bundle)
      }
    }
    .sharedStates(of: session, hasRows: !groups.isEmpty) {
      PartIsEmpty(
        words: String(localized: "Nothing received yet. Gifts show here the day after an occasion.", bundle: #bundle))
    }
  }

  /// I didn't get this, from a Received row: waits for the server, and the row goes. Otherwise an alert says why,
  /// and nothing changes.
  private func restore(_ ask: RestoreAsk) async {
    let outcome = await session.restore(gift: ask.gift.id)
    restoreSaid = RestoreWords.result(of: outcome, address: session.session.instance)
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
  public var name: String {
    switch self {
    case .giving: String(localized: "Giving", bundle: #bundle)
    case .given: String(localized: "Given", bundle: #bundle)
    case .received: String(localized: "Received", bundle: #bundle)
    }
  }
}

/// A group's heading: in Giving, "For Mom and Dad · Christmas", or only the occasion or the reveal date, and in Given
/// and Received, "Christmas · Dec 25, 2025", or only the date. It is plain text in the primary color, and a heading
/// for the VoiceOver rotor.
private struct GiftsHeading: View {
  let words: String

  var body: some View {
    Text(words)
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
/// own line, with its label. From `can_delete`, I won't get this is in the row's context menu and its swipe action,
/// after a confirmation.
///
/// The gift is one element. Its actions are Open, Mark bought or Mark not bought, and I won't get this. The toggle
/// reads "Bought" and its state.
private struct GivingRow: View {
  let gift: GivingGift

  /// The user whose color the tile takes: the gift's first recipient.
  let tileUserID: String
  let session: SessionModel

  /// Asks to confirm I won't get this.
  let wontGetThis: () -> Void

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
        if row.canDelete {
          Button(GiftWords.wontGetThis, action: wontGetThis)
        }
      }
      if row.canEdit {
        BoughtToggle(gift: row, session: session)
          .labelsHidden(!size.isAccessibilitySize)
      }
    }
    .contextMenu {
      if row.canDelete {
        Button(role: .destructive, action: wontGetThis) {
          Label(GiftWords.wontGetThis, systemImage: "xmark.circle")
        }
      }
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      if row.canDelete {
        // The words say what it does, not the color alone. The row stays until the giver confirms.
        Button(action: wontGetThis) {
          Label(GiftWords.wontGetThis, systemImage: "xmark.circle")
        }
        .tint(.red)
      }
    }
  }
}

extension View {
  /// The confirmation of I won't get this: "You won't get {title}?", "Other people can then claim it.", and the
  /// button "I won't get this". Its words never say who else can see anything. `confirm` runs on the button.
  func wontGetThisConfirmation(of gift: Binding<GiftRow?>, confirm: @escaping (GiftRow) -> Void) -> some View {
    confirmationDialog(
      gift.wrappedValue.map { GiftWords.wontGetThisQuestion($0.title) } ?? "",
      isPresented: Binding {
        gift.wrappedValue != nil
      } set: {
        if !$0 { gift.wrappedValue = nil }
      },
      titleVisibility: .visible,
      presenting: gift.wrappedValue
    ) { shown in
      Button(GiftWords.wontGetThis, role: .destructive) {
        confirm(shown)
      }
    } message: { _ in
      Text(GiftWords.wontGetThisMessage)
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

/// A part's empty state: it says so. Giving's also points to Home's people. It grows to its words in a scroll view, as
/// the unreachable view does: the unavailable view alone cuts a larger text short.
private struct PartIsEmpty: View {
  let words: String

  var body: some View {
    GeometryReader { window in
      ScrollView {
        ContentUnavailableView {
          Label {
            Text(words)
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

/// The gift of a Given row: the image and title as they were at reveal, who it went to, and the date it was given.
/// A giver who couldn't see the list has no one to name, so the row leaves that out. It is one element, read in that
/// order, and it opens the gift's page. At the largest text sizes, the image moves above the text.
private struct GivenLabel: View {
  let row: GiftHistoryRow

  var body: some View {
    HistoryLabel(gift: row.gift, tileUserID: row.recipients?.first?.id ?? row.gift.giverID ?? "") {
      if let recipients = row.recipients, !recipients.isEmpty {
        Text(GiftWords.forLine(recipients.map(\.name)))
      }
      if let givenAt = row.gift.givenAt {
        Text(GiftWords.given(givenAt))
      }
    }
  }
}

/// A Received row: the gift, which opens the gift's page. From `can_restore`, I didn't get this is in its context
/// menu and its accessibility actions, after a confirmation. From `can_add_again`, so is Add again, which opens the
/// add form in a sheet, filled from the gift. Its actions are Open, I didn't get this, and Add again.
private struct ReceivedRow: View {
  let row: GiftHistoryRow

  /// The user whose color the tile takes: the recipient.
  let tileUserID: String

  /// Asks to confirm I didn't get this.
  let didntGetThis: () -> Void

  /// Opens the add form, filled from the gift.
  let addAgain: () -> Void

  var body: some View {
    let canRestore = row.gift.canRestore
    let canAddAgain = row.gift.canAddAgain
    let words = RestoreWords.action(of: .sessionUser)
    let addAgainWords = String(localized: "Add again", bundle: #bundle)
    NavigationLink(value: Page.gift(id: row.id)) {
      ReceivedLabel(row: row, tileUserID: tileUserID)
    }
    .accessibilityActions {
      if canRestore {
        Button(words, action: didntGetThis)
      }
      if canAddAgain {
        Button(addAgainWords, action: addAgain)
      }
    }
    .contextMenu {
      if canRestore {
        Button(role: .destructive, action: didntGetThis) {
          Label(words, systemImage: "arrow.uturn.backward")
        }
      }
      if canAddAgain {
        Button(action: addAgain) {
          Label(addAgainWords, systemImage: "plus")
        }
      }
    }
  }
}

/// The gift of a Received row: the image and title, and who gave it, "From Emma · claimed by Mom", or the giver's
/// name. Never the giver's note or bought mark: the server doesn't send them. It is one element, and it opens the
/// gift's page. At the largest text sizes, the image moves above the text.
private struct ReceivedLabel: View {
  let row: GiftHistoryRow

  /// The user whose color the tile takes: the recipient.
  let tileUserID: String

  var body: some View {
    HistoryLabel(gift: row.gift, tileUserID: tileUserID) {
      Text(GiftWords.givenBy(fromLabel: row.gift.fromLabel, giver: row.giverName))
    }
  }
}

/// A given gift's label: the image, the title, then the lines. It is one element.
private struct HistoryLabel<Lines: View>: View {
  let gift: GiftRow
  let tileUserID: String
  @ViewBuilder let lines: Lines

  @Environment(\.dynamicTypeSize) private var size

  var body: some View {
    let layout =
      size.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    layout {
      ItemTile(image: gift.image, userID: tileUserID)
      VStack(alignment: .leading, spacing: 2) {
        Text(gift.title)
          .font(.body.weight(.semibold))
        lines
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }
}
