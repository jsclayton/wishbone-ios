import SwiftUI
import WishboneAPI
import WishboneSession

/// The add form: the user checks what the search found, changes it, and adds the item to their primary list.
/// Nothing is saved until Add. See `docs/screens/add-form.md`, and "What the add form holds" in `docs/spec.md`.
///
/// The form keeps its draft as its own state, with the add's `Idempotency-Key`, so a second Add after a lost
/// answer adds the item once. It shows no claim state.
///
/// Add to, the duplicate hint, and a photo of the user's own come later.
///
/// **Provisional.** Plain default: a system form, in the order of the screen's spec. Add is in the toolbar.
struct AddFormScreen: View {
  let session: SessionModel

  /// The form as it opened, to tell whether the user changed it.
  private let opened: ItemDraft

  /// Called when the item was added. The Add screen closes the form.
  private let didAdd: (AddedItem) -> Void

  @State private var draft: ItemDraft
  @State private var isAdding = false

  /// Why the last Add gave no item, for the line at the top. Nil before any Add, and after one that worked.
  @State private var problem: AddOutcome?
  @State private var isConfirmingDiscard = false

  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  init(session: SessionModel, draft: ItemDraft, didAdd: @escaping (AddedItem) -> Void) {
    self.session = session
    opened = draft
    self.didAdd = didAdd
    _draft = State(initialValue: draft)
  }

  var body: some View {
    Form {
      if let words = problemWords {
        Section {
          Text(words)
        }
      }
      if !draft.images.isEmpty {
        Section {
          ImagePicker(images: $draft.images)
            .listRowInsets(EdgeInsets())
        }
      }
      Section {
        FormRow(label: Text("Title", bundle: #bundle)) {
          TextField(text: $draft.title, prompt: Self.noPrompt) {
            Text("Title", bundle: #bundle)
          }
          .font(.body)
          .accessibilityLabel(Text("Title", bundle: #bundle))
          .onSubmit(add)
        }
      } footer: {
        if !draft.hasTitle {
          Text("Give the item a title.", bundle: #bundle)
        }
      }
      Section {
        priceFields
        if let link = draft.storeLink {
          LabeledContent {
            Text(link.store)
          } label: {
            Text("Store", bundle: #bundle)
          }
        }
      }
      if !draft.options.isEmpty {
        Section {
          ForEach($draft.options) { $option in
            Picker(selection: $option.choice) {
              Text("Not sure", bundle: #bundle).tag(String?.none)
              ForEach(option.values, id: \.self) { value in
                Text(value).tag(String?.some(value))
              }
            } label: {
              Text(option.name)
            }
          }
        }
      }
      Section {
        FormRow(label: Text("Notes", bundle: #bundle)) {
          TextField(text: notes, prompt: Self.noPrompt, axis: .vertical) {
            Text("Notes", bundle: #bundle)
          }
          .font(.body)
          .lineLimit(3...)
          .accessibilityLabel(Text("Notes", bundle: #bundle))
        }
      } footer: {
        if draft.notesWereCut {
          Text("Your notes were cut to 2000 characters.", bundle: #bundle)
        }
      }
    }
    .navigationTitle(Text("Add item", bundle: #bundle))
    .navigationBarBackButtonHidden(hasChanges)
    .disabled(isAdding)
    .toolbar {
      if hasChanges {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            isConfirmingDiscard = true
          } label: {
            Label {
              Text("Back", bundle: #bundle)
            } icon: {
              Image(systemName: "chevron.backward")
            }
          }
          .confirmationDialog(
            Text("Discard this item?", bundle: #bundle), isPresented: $isConfirmingDiscard, titleVisibility: .visible
          ) {
            Button(role: .destructive) {
              dismiss()
            } label: {
              Text("Discard", bundle: #bundle)
            }
            Button(role: .cancel) {
            } label: {
              Text("Keep editing", bundle: #bundle)
            }
          }
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        addButton
      }
    }
  }

  /// Add: disabled, and saying why, until the form has a title. It shows progress while the images upload and
  /// the item is added.
  private var addButton: some View {
    Button(action: add) {
      if isAdding {
        ProgressView()
      } else {
        Text("Add", bundle: #bundle)
      }
    }
    .keyboardShortcut(.defaultAction)
    .disabled(!draft.hasTitle || isAdding)
    .accessibilityHint(
      draft.hasTitle
        ? Text("Adds the item to your list.", bundle: #bundle) : Text("Give the item a title.", bundle: #bundle))
  }

  /// A field's label is above it, so the field has no prompt of its own.
  private static let noPrompt = Text(String())

  /// Price and Up to, side by side, and stacked at the largest text sizes.
  @ViewBuilder private var priceFields: some View {
    let layout =
      dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
    layout {
      priceField(\.priceMinor, label: Text("Price", bundle: #bundle))
      priceField(\.topPriceMinor, label: Text("Up to", bundle: #bundle))
    }
  }

  private func priceField(_ field: WritableKeyPath<ItemDraft, Int?>, label: Text) -> some View {
    FormRow(label: label) {
      TextField(value: price(field), format: .currency(code: draft.currency), prompt: Self.noPrompt) {
        label
      }
      .font(.body)
      .accessibilityLabel(label)
      #if os(iOS)
        .keyboardType(.decimalPad)
      #endif
    }
  }

  /// A price of the draft in the currency's main unit, for a field: "24.99" for 2499 cents.
  private func price(_ field: WritableKeyPath<ItemDraft, Int?>) -> Binding<Decimal?> {
    let unit = Decimal(minorUnit)
    return Binding {
      draft[keyPath: field].map { Decimal($0) / unit }
    } set: { value in
      draft[keyPath: field] = value.map { value in
        var minor = value * unit
        var rounded = Decimal()
        NSDecimalRound(&rounded, &minor, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
      }
    }
  }

  /// How many minor units the draft's currency has in its main unit: 100 for USD, 1 for JPY.
  private var minorUnit: Int {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = draft.currency
    return (0..<formatter.maximumFractionDigits).reduce(1) { value, _ in value * 10 }
  }

  /// The notes, at most 2000 characters.
  private var notes: Binding<String> {
    Binding {
      draft.notes
    } set: { notes in
      draft.notes = String(notes.prefix(ItemDraft.notesLimit))
    }
  }

  private var hasChanges: Bool {
    draft != opened
  }

  /// The line at the top after an Add that gave no item.
  private var problemWords: String? {
    switch problem {
    case .unreachable: CantReach.words(for: session.session.instance)
    case .refused(let refusal) where refusal.code == .storeBlocked:
      String(
        localized: "Links from \(draft.storeLink?.store ?? "") are blocked on this Wishbone.", bundle: #bundle)
    case .refused(let refusal): ErrorWords.words(for: refusal)
    case .failed: ErrorWords.fault
    case .added, nil: nil
    }
  }

  /// Uploads the ticked images, then adds the item. The form stays open when the add gives no item.
  private func add() {
    guard draft.hasTitle, !isAdding else { return }
    isAdding = true
    Task {
      var sent = draft
      let outcome = await session.add(&sent)
      draft = sent
      isAdding = false
      if case .added(let item) = outcome {
        problem = nil
        didAdd(item)
      } else {
        problem = outcome
        if let words = problemWords { AccessibilityNotification.Announcement(words).post() }
      }
    }
  }
}

/// The images that the search found, to tick, in a row that scrolls sideways. The first ticked is the primary
/// image. Each is a store's image, which loads with no token.
private struct ImagePicker: View {
  @Binding var images: [ItemDraft.Image]

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 12) {
        ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
          Button {
            images[index].isTicked.toggle()
          } label: {
            ImageTile(image: image, isPrimary: images.firstIndex(where: \.isTicked) == index)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(Text("Photo \(index + 1) of \(images.count)", bundle: #bundle))
          .accessibilityValue(value(of: image, at: index))
          .accessibilityAddTraits(image.isTicked ? .isSelected : [])
        }
      }
      .padding()
    }
  }

  private func value(of image: ItemDraft.Image, at index: Int) -> Text {
    if !image.isTicked { return Text("Not selected", bundle: #bundle) }
    if images.firstIndex(where: \.isTicked) == index { return Text("Selected, primary", bundle: #bundle) }
    return Text("Selected", bundle: #bundle)
  }
}

/// One image to tick, with a mark when it is ticked.
private struct ImageTile: View {
  let image: ItemDraft.Image
  let isPrimary: Bool

  var body: some View {
    AsyncImage(url: URL(string: image.url)) { loaded in
      loaded.resizable().scaledToFill()
    } placeholder: {
      Rectangle().fill(.quaternary)
    }
    .frame(width: 96, height: 96)
    .clipShape(.rect(cornerRadius: 12))
    .overlay(alignment: .topTrailing) {
      Image(systemName: image.isTicked ? "checkmark.circle.fill" : "circle")
        .font(.title3)
        .foregroundStyle(image.isTicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .background(Circle().fill(.background))
        .padding(6)
    }
    .overlay(alignment: .bottomLeading) {
      if isPrimary {
        Image(systemName: "star.fill")
          .font(.caption)
          .padding(6)
          .background(Circle().fill(.background))
          .padding(6)
      }
    }
  }
}
