import SwiftUI
import WishboneSession

/// A gift's page, for an open gift, as its giver reads it: the item's image, title and price, the list, who the gift
/// is for, each flag in words with every change of a changed item, then Bought, How many, Occasion with the reveal
/// date, From, and Note. See `docs/screens/gift.md`.
///
/// From `can_edit`: Bought is a toggle, How many a stepper, and From and Note are text fields that save when they lose
/// focus. Each is an unsent change, except a raise of how many, which waits for the server. Occasion is read here.
/// It becomes a control in a later step.
///
/// From `can_acknowledge`, each flag has its answer: Keep it for an item that was removed, and OK for the rest. From
/// `can_delete`, I won't get this sits at the foot, after a confirmation. Each is an unsent change. After I won't get
/// this, the page closes in this window, which shows what was under it.
///
/// **Only its giver sees an open gift,** and the page never says who else claimed the item. Nothing on it goes to a
/// system surface or into the shared container.
///
/// **Provisional.** Plain default: a system list in one column of readable width. The image and title are the
/// header, the flags are the first section, and each field is a row.
struct GiftPageScreen: View {
  let page: GiftPage
  let session: SessionModel

  /// The window's pages on the tab, so that I won't get this closes this page.
  @Binding var pages: [Page]

  /// The gift that I won't get this asks about.
  @State private var confirmingUnclaim: GiftRow?

  /// The width of the window, for the list's column of readable width.
  @State private var width: CGFloat = 0
  @ScaledMetric(relativeTo: .body) private var readableWidth: CGFloat = 640
  @Environment(\.dynamicTypeSize) private var size

  var body: some View {
    let gift = page.gift
    List {
      Section {
        if page.linksItem {
          NavigationLink(value: Page.item(id: gift.itemID)) {
            GiftHeader(gift: gift, tileUserID: page.recipients?.first?.id ?? gift.giverID ?? "")
          }
        } else {
          GiftHeader(gift: gift, tileUserID: page.recipients?.first?.id ?? gift.giverID ?? "")
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
            FlagRow(flag: flag, changes: page.changes, canAnswer: gift.canAcknowledge) {
              Task { await session.answer(flag, ofGift: gift.id) }
            }
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
          QuantityStepper(gift: gift, session: session)
        }
        FieldRow(label: String(localized: "Occasion", bundle: #bundle)) {
          VStack(alignment: .trailing, spacing: 2) {
            Text(GiftWords.occasion(page.occasion))
            if case .named = page.occasion {
              Text(GiftWords.hiddenUntil(gift.revealAt))
                .font(.footnote)
            }
          }
        }
        if gift.canEdit {
          GiftTextField(
            field: .fromLabel, giftID: gift.id, saved: gift.fromLabel ?? "",
            save: { await session.setFromLabel(gift: gift.id, $0) })
        } else {
          FieldRow(label: String(localized: "From", bundle: #bundle)) {
            if let label = gift.fromLabel, !label.isEmpty {
              Text(label)
            } else {
              Text("Who it's from, if not only you", bundle: #bundle)
                .foregroundStyle(.secondary)
            }
          }
        }
      } footer: {
        // At the largest text sizes, a field's prompt doesn't fit on its one line, so the From field's prompt is
        // the section's footer, whole.
        if gift.canEdit && size.isAccessibilitySize {
          Text("Who it's from, if not only you", bundle: #bundle)
        }
      }
      Section {
        if gift.canEdit {
          GiftTextField(
            field: .note, giftID: gift.id, saved: gift.note.value ?? "",
            save: { await session.setNote(gift: gift.id, $0) })
        } else {
          FieldRow(label: String(localized: "Note", bundle: #bundle)) {
            if let note = gift.note.value, !note.isEmpty {
              Text(note)
            }
          }
        }
      } footer: {
        Text("Only you see this note.", bundle: #bundle)
      }
      if gift.canDelete {
        Section {
          Button(role: .destructive) {
            confirmingUnclaim = gift
          } label: {
            Text(GiftWords.wontGetThis)
              .frame(maxWidth: .infinity)
          }
        }
      }
    }
    .wontGetThisConfirmation(of: $confirmingUnclaim) { gift in
      unclaim(gift)
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

  /// I won't get this: the page closes in this window first, so it never shows the "not found" page here. Then the
  /// unclaim is saved as an unsent change, and every other window that shows the page shows the "not found" page.
  private func unclaim(_ gift: GiftRow) {
    if let index = pages.lastIndex(of: .gift(id: gift.id)) {
      pages.removeSubrange(index...)
    }
    Task { await session.unclaim(gift: gift.id) }
  }
}

/// How many, a stepper. Lowering is an unsent change: it shows at once. Raising waits for the server, says "Raising"
/// meanwhile, and says in place why it didn't raise. It can't go higher without `can_raise_quantity`, or lower than
/// one. VoiceOver reads "How many, {n}", and says when it can't go higher.
private struct QuantityStepper: View {
  let gift: GiftRow
  let session: SessionModel

  @State private var isRaising = false
  @State private var said: String?

  var body: some View {
    let canRaise = gift.canRaiseQuantity && !isRaising
    Stepper(
      onIncrement: canRaise ? { Task { await raise() } } : nil,
      onDecrement: canLower ? { Task { await lower() } } : nil
    ) {
      HStack(spacing: 8) {
        Text("How many", bundle: #bundle)
        Spacer(minLength: 8)
        if isRaising {
          ProgressView()
            .accessibilityHidden(true)
        }
        Text(gift.quantity.formatted())
          .monospacedDigit()
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("How many", bundle: #bundle))
    .accessibilityValue(Text(GiftWords.howManyValue(gift.quantity, canRaise: gift.canRaiseQuantity)))
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment where canRaise: Task { await raise() }
      case .decrement where canLower: Task { await lower() }
      default: break
      }
    }
    // A new gift in the same window starts with nothing said.
    .onChange(of: gift.id) {
      said = nil
    }
    if let said {
      Text(said)
    }
  }

  private var canLower: Bool {
    gift.quantity > 1 && !isRaising
  }

  /// Lowers by one, as an unsent change: it shows at once.
  private func lower() async {
    said = nil
    await session.lowerQuantity(gift: gift.id, to: gift.quantity - 1)
  }

  private func raise() async {
    guard !isRaising else { return }
    isRaising = true
    said = nil
    let outcome = await session.raiseQuantity(gift: gift.id)
    isRaising = false
    said = GiftWords.raiseResult(of: outcome, address: session.session.instance)
    if let said { AccessibilityNotification.Announcement(said).post() }
  }
}

/// A text field of a gift, From or Note, that saves once when it loses focus, as an unsent change. `GiftFieldDraft`
/// holds what it shows and when it saves. The from label stops at 60 characters, and the note at 2000. The note's
/// Return adds a line, so a Done key above the keyboard ends its editing. The from label wraps, so its words are
/// never cut short at a larger text size, and its Return ends the editing.
///
/// The label shows, and is paired with the field for accessibility, so VoiceOver reads the field by its label.
private struct GiftTextField: View {
  typealias Field = GiftFieldDraft.Field

  let field: Field
  let giftID: String
  let saved: String
  let save: (String) async -> Void

  @State private var draft: GiftFieldDraft
  @FocusState private var isFocused: Bool
  @Environment(\.dynamicTypeSize) private var size
  @Namespace private var pair

  init(field: Field, giftID: String, saved: String, save: @escaping (String) async -> Void) {
    self.field = field
    self.giftID = giftID
    self.saved = saved
    self.save = save
    _draft = State(initialValue: GiftFieldDraft(field, saved: saved))
  }

  var body: some View {
    let layout =
      size.isAccessibilitySize || field == .note
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
      : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 16))
    layout {
      Text(label)
        .accessibilityLabeledPair(role: .label, id: field, in: pair)
      textField
        .focused($isFocused)
        .accessibilityLabel(Text(label))
        .accessibilityLabeledPair(role: .content, id: field, in: pair)
    }
    .onChange(of: isFocused) {
      if isFocused { draft.began() } else { saveIfEdited() }
    }
    .onChange(of: saved) {
      draft.savedChanged(to: saved)
    }
    .onChange(of: giftID) {
      draft.reset(to: saved)
    }
    .onDisappear {
      // A page that closes while the field has focus still saves what was typed. When the focus change saved it
      // first, this saves nothing.
      saveIfEdited()
    }
  }

  private func saveIfEdited() {
    guard let text = draft.ended() else { return }
    Task { [save] in await save(text) }
  }

  @ViewBuilder
  private var textField: some View {
    switch field {
    case .fromLabel:
      TextField(
        text: oneLine,
        // A prompt stays on one line, so at the largest text sizes it is the section's footer instead, and the
        // field shows its label.
        prompt: size.isAccessibilitySize ? nil : Text("Who it's from, if not only you", bundle: #bundle),
        axis: .vertical
      ) {
        Text(label)
      }
      .lineLimit(1...3)
      .multilineTextAlignment(size.isAccessibilitySize ? .leading : .trailing)
      .submitLabel(.done)
      .onSubmit { isFocused = false }
    case .note:
      TextField(text: $draft.text, axis: .vertical) {
        Text(label)
      }
      .lineLimit(3...)
      .toolbar {
        ToolbarItemGroup(placement: .keyboard) {
          if isFocused {
            Spacer()
            Button {
              isFocused = false
            } label: {
              Text("Done", bundle: #bundle)
            }
          }
        }
      }
    }
  }

  /// The from label's text, on one line. The field wraps, so Return would add a line: instead, it ends the editing.
  private var oneLine: Binding<String> {
    Binding {
      draft.text
    } set: { text in
      guard text.contains(where: \.isNewline) else {
        draft.text = text
        return
      }
      draft.text = String(text.filter { !$0.isNewline })
      isFocused = false
    }
  }

  private var label: String {
    switch field {
    case .fromLabel: String(localized: "From", bundle: #bundle)
    case .note: String(localized: "Note", bundle: #bundle)
    }
  }
}

/// The header: the item's image, its title as large text, and its price, as they are now, as they were when the
/// item was removed, or as they were at reveal. At the largest text sizes, the image moves above the text.
struct GiftHeader: View {
  let gift: GiftRow

  /// The user whose color the tile takes.
  let tileUserID: String

  @Environment(\.dynamicTypeSize) private var size

  var body: some View {
    let layout =
      size.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    layout {
      ItemTile(image: gift.image, userID: tileUserID)
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

/// A flag, in words, with its answer, from `can_acknowledge`: Keep it for an item that was removed, and OK for the
/// rest. A changed item lists each change under it, old to new. The flag and its changes are one element, and its
/// answer is that element's action. The button is also on screen.
private struct FlagRow: View {
  let flag: GivingGift.Flag
  let changes: [GiftPage.Change]
  let canAnswer: Bool
  let answer: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
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
      .accessibilityElement(children: .combine)
      .accessibilityActions {
        if canAnswer {
          Button(GiftWords.answer(to: flag), action: answer)
        }
      }
      if canAnswer {
        // Bordered, so that only the button takes a tap, and not the whole row.
        Button(GiftWords.answer(to: flag), action: answer)
          .buttonStyle(.bordered)
          .accessibilityHidden(true)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// A field: its label, and its value at the trailing edge. At the largest text sizes, the label sits above the
/// value. The row is one element.
struct FieldRow<Value: View>: View {
  let label: String
  @ViewBuilder let value: Value

  @Environment(\.dynamicTypeSize) private var size

  var body: some View {
    Group {
      if size.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 4) {
          Text(label)
          value
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        HStack(alignment: .firstTextBaseline) {
          Text(label)
          Spacer(minLength: 16)
          value
            .multilineTextAlignment(.trailing)
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .combine)
  }
}
