import SwiftUI
import WishboneAPI
import WishboneSession

/// The add form: the user checks what the search found, changes it, and adds the item to the list in Add to, or to
/// the list that the form is fixed to. Nothing is saved until Add. See `docs/screens/add-form.md`, and "What the add
/// form holds" and "Which list" in `docs/spec.md`.
///
/// The form keeps its draft as its own state, with the add's `Idempotency-Key`, so a second Add after a lost
/// answer adds the item once. It shows no claim state. Add to offers only the lists that the user can edit, and the
/// duplicate hint reads only what the user sees on the list.
///
/// A photo that the user took or chose is the item's image, above the title. It goes only to the instance.
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
      // The note, or why the last Add gave no item, is the form's first element: VoiceOver reads why the form is
      // blank before the fields.
      if let words = problemWords ?? noteWords {
        Section {
          Text(words)
        }
      }
      if let photo = draft.photo {
        Section {
          PhotoTile(photo: photo)
        }
      }
      if !draft.images.isEmpty {
        Section {
          ImagePicker(images: $draft.images)
            .listRowInsets(EdgeInsets())
        }
      }
      Section {
        // The title wraps, so a long one is never cut short. It is one line of text, so Return adds the item.
        TextField(text: title, prompt: Text("Title", bundle: #bundle), axis: .vertical) {
          Text("Title", bundle: #bundle)
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
      if let addTo = session.addTo(for: draft) {
        Section {
          AddToPicker(addTo: addTo, selection: listChoice)
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
        TextField(text: notes, prompt: Text("Notes", bundle: #bundle), axis: .vertical) {
          Text("Notes", bundle: #bundle)
        }
        .lineLimit(3...)
      } footer: {
        if draft.notesWereCut {
          Text("Your notes were cut to 2000 characters.", bundle: #bundle)
        }
      }
      if let hint = session.duplicateHint(for: draft) {
        Section {
          DuplicateHintRow(hint: hint, session: session)
        }
      }
    }
    .navigationTitle(Text("Add item", bundle: #bundle))
    .navigationBarBackButtonHidden(hasChanges)
    // In a list's sheet, a swipe down doesn't close the sheet while the form has typed changes: Back asks first.
    // On the Add screen's place, there is no sheet, and this does nothing.
    .interactiveDismissDisabled(hasChanges)
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
        ? Text("Adds the item to the list.", bundle: #bundle) : Text("Give the item a title.", bundle: #bundle))
  }

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
    TextField(value: price(field), format: .currency(code: draft.currency)) {
      label
    }
    #if os(iOS)
      .keyboardType(.decimalPad)
    #endif
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

  /// The title, on one line: Return adds the item.
  private var title: Binding<String> {
    Binding {
      draft.title
    } set: { title in
      guard title.contains(where: \.isNewline) else {
        draft.title = title
        return
      }
      draft.title = title.filter { !$0.isNewline }
      add()
    }
  }

  /// The list in Add to: the one picked, or the primary list, where every form starts.
  private var listChoice: Binding<String> {
    Binding {
      draft.listID ?? session.primaryList?.id ?? ""
    } set: { id in
      draft.listID = id
    }
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

  /// The note at the top when search did not fill in the form, or when an add dropped a blocked link.
  private var noteWords: String? {
    switch draft.note {
    case .overLimit:
      String(
        localized:
          "This link wasn't read: you've read 30 links and photos in the last hour. Fill it in yourself, or try again later.",
        bundle: #bundle)
    case .nothingFound(let store):
      String(localized: "Nothing could be read from \(store). Fill it in yourself.", bundle: #bundle)
    case .photoNotRead:
      String(localized: "Nothing could be read from your photo. Give it a title.", bundle: #bundle)
    case .blocked(let store): ErrorWords.blocked(store)
    case nil: nil
    }
  }

  /// The line at the top after an Add that gave no item. A blocked store's line is the draft's note.
  private var problemWords: String? {
    switch problem {
    case .unreachable: CantReach.words(for: session.session.instance)
    case .refused(let refusal) where refusal.code == .storeBlocked: nil
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
        if let words = problemWords ?? noteWords { AccessibilityNotification.Announcement(words).post() }
      }
    }
  }
}

/// Add to: pushes a picker of the lists that the user can edit, in the Lists tab's order, with a child's lists under
/// the child's name. The row reads the list, with its recipients' names when the user is not one.
private struct AddToPicker: View {
  let addTo: AddTo
  @Binding var selection: String

  var body: some View {
    Picker(selection: $selection) {
      ForEach(addTo.yourLists) { target in
        AddTargetName(target: target).tag(target.id)
      }
      ForEach(addTo.children) { part in
        Section {
          ForEach(part.targets) { target in
            AddTargetName(target: target).tag(target.id)
          }
        } header: {
          Text(part.child.name)
        }
      }
    } label: {
      Text("Add to", bundle: #bundle)
    }
    #if os(iOS)
      .pickerStyle(.navigationLink)
    #endif
  }
}

/// "Already on this list: {title}". On the Add screen it pushes the item's page over the form, so Back returns to
/// the form with its changes. In a sheet it is text, because a sheet never opens a second sheet. It never blocks the
/// add.
private struct DuplicateHintRow: View {
  let hint: DuplicateHint
  let session: SessionModel

  var body: some View {
    if hint.opensItem {
      // The page is pushed by view, not by value. The Add screen pushes the form by view, and the stack keeps the
      // pages pushed by view on top of its path, so a page pushed by value would go under the form. The item's
      // page has no window pages of its own here, and a link on it that pushes by value goes under the form too.
      NavigationLink {
        PageScreen(page: .item(id: hint.itemID), session: session, pages: .constant([]))
      } label: {
        words
      }
    } else {
      words
    }
  }

  private var words: some View {
    Text("Already on this list: \(hint.title)", bundle: #bundle)
      .fixedSize(horizontal: false, vertical: true)
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

/// The photo that the user took or chose: the item's image. It is not ticked: an item from a photo has that one
/// image. The picture is made away from the main actor, once for each photo.
private struct PhotoTile: View {
  let photo: Photo

  @State private var preview: CGImage?

  var body: some View {
    HStack {
      Spacer(minLength: 0)
      Group {
        if let preview {
          Image(decorative: preview, scale: 1)
            .resizable()
            .scaledToFit()
        } else {
          Rectangle().fill(.quaternary)
        }
      }
      .frame(maxWidth: 240, maxHeight: 240)
      .clipShape(.rect(cornerRadius: 12))
      Spacer(minLength: 0)
    }
    .accessibilityElement()
    .accessibilityLabel(Text("Your photo", bundle: #bundle))
    .accessibilityAddTraits(.isImage)
    .task(id: photo.id) { preview = await Self.preview(of: photo) }
  }

  @concurrent nonisolated private static func preview(of photo: Photo) async -> CGImage? {
    photo.preview(longestSide: 720)
  }
}
