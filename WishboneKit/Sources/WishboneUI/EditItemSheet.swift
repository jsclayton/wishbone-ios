import PhotosUI
import SwiftUI
import WishboneAPI
import WishboneSession

#if os(iOS)
  import AVFoundation
  import UIKit
#endif

/// The Edit item sheet: the photos, the title, the price and Up to, how many or Always wanted, the notes, and the
/// store links. Save is an unsent change: it shows at once, in every window, and reaches the instance when it
/// answers. A new photo is uploaded first. A store link's price edit and its Remove are saved with it. Add link
/// waits for the server, which reads the page, and isn't part of Save. See "Edit item" in `docs/screens/item.md`.
///
/// Take a photo and Choose a photo open the system's own camera and photo picker, which a sheet may open.
///
/// **Provisional.** Plain default: a system form in a sheet, in the order of the screen's spec, with Cancel and Save
/// in the toolbar. Each photo is a row with its picture, "Primary photo" or Make primary, and Remove. Each store link
/// is a row with its store, its price in a field, and Remove, then a field for a pasted address and Add link. A
/// swipe down doesn't close the sheet while it has typed changes: Cancel asks first.
///
/// The sheet opens with the draft that the session gives (`SessionModel.editDraft(ofItem:)`): it has the photos whose
/// uploads wait, so the user can keep, remove or pick each one, and Save never drops one that the sheet didn't show.
/// Until the draft is read, the sheet shows the system's progress indicator.
struct EditItemSheet: View {
  let item: ItemRow
  let session: SessionModel

  @State private var opened: ItemEditDraft?

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    if let opened {
      EditItemForm(item: item, opened: opened, session: session)
    } else {
      NavigationStack {
        ProgressView()
          .navigationTitle(Text("Edit item", bundle: #bundle))
          #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
          #endif
      }
      .task {
        // An item that left the copy meanwhile has nothing to edit.
        guard let draft = await session.editDraft(ofItem: item.id) else {
          dismiss()
          return
        }
        opened = draft
      }
    }
  }
}

/// The form of the Edit item sheet, with the draft that it opened with.
private struct EditItemForm: View {
  let item: ItemRow
  let session: SessionModel

  /// The draft as the sheet opened: what Save compares with, so it sends only what the user changed, and what tells
  /// whether the user changed something. A store link that Add link added joins it, because the server has it.
  @State private var opened: ItemEditDraft

  @State private var draft: ItemEditDraft
  @State private var isConfirmingDiscard = false
  @State private var isChoosingPhoto = false
  @State private var chosenPhoto: PhotosPickerItem?

  #if os(iOS)
    /// Whether Take a photo can open the camera. It is read again each time the app comes back, as from Settings.
    @State private var camera = CameraAccess.forPhotos
    @State private var isTakingPhoto = false
    @Environment(\.scenePhase) private var scenePhase
  #endif

  @Environment(\.dismiss) private var dismiss

  init(item: ItemRow, opened: ItemEditDraft, session: SessionModel) {
    self.item = item
    self.session = session
    _opened = State(initialValue: opened)
    _draft = State(initialValue: opened)
  }

  var body: some View {
    NavigationStack {
      Form {
        photos
        Section {
          TextField(text: limited($draft.title, to: ItemDraft.titleLimit), prompt: Text("Title", bundle: #bundle)) {
            Text("Title", bundle: #bundle)
          }
        } header: {
          Text("Title", bundle: #bundle)
        } footer: {
          if !draft.hasTitle {
            Text("Give the item a title.", bundle: #bundle)
          }
        }
        Section {
          PriceFields(priceMinor: $draft.priceMinor, topPriceMinor: $draft.topPriceMinor, currency: draft.currency)
        }
        Section {
          Toggle(isOn: $draft.isUnlimited) {
            Text("Always wanted", bundle: #bundle)
          }
          if !draft.isUnlimited {
            Stepper(value: $draft.quantity, in: 1...ItemEditDraft.quantityLimit) {
              LabeledContent {
                Text(draft.quantity, format: .number)
              } label: {
                Text("How many", bundle: #bundle)
              }
            }
          }
        } header: {
          Text("How many", bundle: #bundle)
        }
        Section {
          TextField(
            text: limited($draft.notes, to: ItemDraft.notesLimit), prompt: Text("Notes", bundle: #bundle),
            axis: .vertical
          ) {
            Text("Notes", bundle: #bundle)
          }
          .lineLimit(3...)
        } header: {
          Text("Notes", bundle: #bundle)
        }
        StoreLinksSection(item: item, session: session, opened: $opened, draft: $draft)
      }
      .navigationTitle(Text("Edit item", bundle: #bundle))
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .interactiveDismissDisabled(hasChanges)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            if hasChanges { isConfirmingDiscard = true } else { dismiss() }
          } label: {
            Text("Cancel", bundle: #bundle)
          }
          .confirmationDialog(
            Text("Discard your changes?", bundle: #bundle), isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
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
        ToolbarItem(placement: .confirmationAction) {
          Button {
            Task {
              await session.editItem(item.id, from: opened, to: draft)
              dismiss()
            }
          } label: {
            Text("Save", bundle: #bundle)
          }
          .keyboardShortcut(.defaultAction)
          .disabled(!draft.hasTitle)
          .accessibilityHint(
            draft.hasTitle
              ? Text("Saves the item.", bundle: #bundle) : Text("Give the item a title.", bundle: #bundle))
        }
      }
    }
    // The system photo picker runs outside the app: it needs no photo library permission.
    .photosPicker(isPresented: $isChoosingPhoto, selection: $chosenPhoto, matching: .images)
    .task(id: chosenPhoto) { await addChosenPhoto() }
    #if os(iOS)
      .fullScreenCover(isPresented: $isTakingPhoto) {
        CameraPicker { taken in
          // The camera's photo has no file yet. The JPEG at full quality keeps its orientation for the encoder.
          guard let file = taken.jpegData(compressionQuality: 1) else { return }
          Task { add(await Self.photo(of: file)) }
        }
        .ignoresSafeArea()
      }
      .onChange(of: scenePhase) {
        if scenePhase == .active { camera = .forPhotos }
      }
    #endif
  }

  /// The photos, each with Make primary and Remove, then Take a photo and Choose a photo while the item has fewer
  /// than 5.
  private var photos: some View {
    Section {
      ForEach(Array(draft.photos.enumerated()), id: \.element.id) { index, photo in
        PhotoRow(
          photo: photo, number: index + 1, isPrimary: photo.id == draft.primaryID, session: session,
          tileUserID: session.list(id: item.listID)?.recipientIDs.first ?? "",
          makePrimary: { draft.makePrimary(photo.id) }, remove: { draft.remove(photo.id) })
      }
      takeAPhoto
      Button {
        isChoosingPhoto = true
      } label: {
        Text("Choose a photo", bundle: #bundle)
      }
      .disabled(!draft.canAddPhoto)
    } header: {
      Text("Photos", bundle: #bundle)
    } footer: {
      if !draft.canAddPhoto {
        Text(ErrorWords.tooManyImages)
      } else {
        #if os(iOS)
          if let reason = camera.photoReason {
            Text(reason)
          }
        #endif
      }
    }
  }

  /// Take a photo: the system camera, for one photo. Where the camera is denied or turned off, the row can't open
  /// it, and the footer says why. A device with no camera has no row.
  @ViewBuilder private var takeAPhoto: some View {
    #if os(iOS)
      if camera.showsTakeAPhoto {
        Button {
          Task { await takePhoto() }
        } label: {
          Text("Take a photo", bundle: #bundle)
        }
        .disabled(camera != .allowed || !draft.canAddPhoto)
      }
    #endif
  }

  /// Whether the user changed something that isn't saved.
  private var hasChanges: Bool {
    draft != opened
  }

  /// Adds the photo. A file that the device couldn't read as an image adds nothing.
  private func add(_ photo: Photo?) {
    guard let photo else { return }
    draft.add(photo)
  }

  /// Adds the photo that the user chose in the system photo picker.
  private func addChosenPhoto() async {
    guard let chosenPhoto else { return }
    defer { self.chosenPhoto = nil }
    guard let file = try? await chosenPhoto.loadTransferable(type: Data.self) else { return }
    add(await Self.photo(of: file))
  }

  #if os(iOS)
    /// Opens the camera. The first tap asks for the camera, and the camera opens only if the person allows it.
    private func takePhoto() async {
      if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
        _ = await AVCaptureDevice.requestAccess(for: .video)
      }
      camera = .forPhotos
      isTakingPhoto = camera == .allowed
    }
  #endif

  /// The photo of the file, as a JPEG under the server's limit, made away from the main actor. Nil when the device
  /// can't read the file as an image. An item's photo needs no title of its own.
  @concurrent nonisolated private static func photo(of file: Data) async -> Photo? {
    Photo(file: file) { _ in String() }
  }

  /// The text, cut to the server's limit as it is typed.
  private func limited(_ text: Binding<String>, to limit: Int) -> Binding<String> {
    Binding {
      text.wrappedValue
    } set: {
      text.wrappedValue = String($0.prefix(limit))
    }
  }
}

/// A photo of the Edit item sheet: its picture, then "Primary photo", or Make primary, and Remove. VoiceOver reads
/// it as one element, "Photo {n}", with "Primary photo", and offers Make primary and Remove as its actions.
private struct PhotoRow: View {
  let photo: ItemEditDraft.PhotoEntry
  let number: Int
  let isPrimary: Bool

  /// Where a photo whose upload waits gets its bytes.
  let session: SessionModel

  /// The user whose color the tile takes while a saved image loads.
  let tileUserID: String
  let makePrimary: () -> Void
  let remove: () -> Void

  @State private var preview: CGImage?

  var body: some View {
    HStack(spacing: 12) {
      picture
        .frame(width: 56, height: 56)
        .clipShape(.rect(cornerRadius: 8))
      VStack(alignment: .leading, spacing: 4) {
        Text("Photo \(number)", bundle: #bundle)
        if isPrimary {
          Text("Primary photo", bundle: #bundle)
            .font(.subheadline)
        } else {
          Button(action: makePrimary) {
            Text("Make primary", bundle: #bundle)
          }
          .buttonStyle(.borderless)
        }
      }
      Spacer(minLength: 0)
      Button(role: .destructive, action: remove) {
        Text("Remove", bundle: #bundle)
      }
      .buttonStyle(.borderless)
    }
    .accessibilityElement(children: .combine)
    .accessibilityActions {
      if !isPrimary {
        Button(action: makePrimary) {
          Text("Make primary", bundle: #bundle)
        }
      }
      Button(action: remove) {
        Text("Remove", bundle: #bundle)
      }
    }
  }

  @ViewBuilder private var picture: some View {
    switch photo {
    case .saved(let image):
      SessionImage(image: image) { tile }
    case .waiting(let id):
      // From the journal's bytes while the upload waits. Once it is sent, the bytes are gone: the tile shows.
      previewed
        .task(id: id) {
          guard let data = await session.waitingPhoto(id) else { return }
          preview = await Self.preview(of: Photo(data: data, untitled: String()))
        }
    case .new(let photo):
      previewed
        .task(id: photo.id) { preview = await Self.preview(of: photo) }
    }
  }

  /// The preview of the photo's bytes, or the tile until it is made.
  @ViewBuilder private var previewed: some View {
    if let preview {
      Image(decorative: preview, scale: 1)
        .resizable()
        .scaledToFill()
    } else {
      tile
    }
  }

  private var tile: some View {
    Rectangle().fill(PersonPalette.color(forUserID: tileUserID).opacity(0.15))
  }

  @concurrent nonisolated private static func preview(of photo: Photo) async -> CGImage? {
    photo.preview(longestSide: 168)
  }
}

/// The store links of the Edit item sheet: each with its price to edit and Remove, then Add link, which takes a pasted
/// web address. A price edit and a Remove wait for Save. Add link waits for the server's answer, and a link that it
/// adds is in the item at once: Cancel doesn't take it away. What Add link said shows under the section.
///
/// A link of an item that waits to be created shows its price, with no field and no Remove, until the server has the
/// item. At 10 links, Add link can't be used, and the section says why.
private struct StoreLinksSection: View {
  let item: ItemRow
  let session: SessionModel
  @Binding var opened: ItemEditDraft
  @Binding var draft: ItemEditDraft

  /// The address that the user pasted or typed, for Add link.
  @State private var address = ""
  @State private var isAdding = false

  /// What the last Add link said, when it added nothing.
  @State private var said: String?

  var body: some View {
    Section {
      ForEach($draft.storeLinks) { $link in
        StoreLinkEditRow(link: $link) { draft.removeStoreLink(link.id) }
      }
      addLink
    } header: {
      Text("Store links", bundle: #bundle)
    } footer: {
      if !draft.canAddStoreLink {
        Text(ErrorWords.tooManyStoreLinks)
      } else if let said {
        Text(said)
      }
    }
  }

  /// The field for a pasted address, and Add link, which shows progress while the server reads the page.
  private var addLink: some View {
    HStack {
      TextField(text: $address, prompt: Text("Paste a store's web address", bundle: #bundle)) {
        Text("Paste a store's web address", bundle: #bundle)
      }
      #if os(iOS)
        .keyboardType(.URL)
        .textInputAutocapitalization(.never)
      #endif
      .textContentType(.URL)
      .autocorrectionDisabled()
      .onSubmit { Task { await add() } }
      .disabled(isAdding || !draft.canAddStoreLink)
      Button {
        Task { await add() }
      } label: {
        if isAdding {
          ProgressView {
            Text("Add link", bundle: #bundle)
          }
        } else {
          Text("Add link", bundle: #bundle)
        }
      }
      .buttonStyle(.borderless)
      .disabled(!canAdd)
    }
  }

  /// Whether Add link can go: the field has a web address, the item has fewer than 10 links, and no add waits.
  private var canAdd: Bool {
    guard !isAdding, draft.canAddStoreLink, case .link? = SearchInput(address) else { return false }
    return true
  }

  /// Adds the link, and waits for the server. A link that the server added joins the sheet, and the field empties.
  /// An item with no price takes the link's, in the sheet too, unless the user typed one. Anything else says why
  /// nothing was added, and keeps the address in the field.
  private func add() async {
    guard canAdd else { return }
    isAdding = true
    said = nil
    let outcome = await session.addStoreLink(address, toItem: item.id)
    isAdding = false
    switch outcome {
    case .added(let link):
      opened.added(link)
      draft.added(link)
      if opened.priceMinor == nil, let price = session.item(id: item.id)?.priceMinor {
        if draft.priceMinor == nil { draft.priceMinor = price }
        opened.priceMinor = price
      }
      address = ""
      return
    case .unreachable:
      said = CantReach.words(for: session.session.instance)
    case .blocked(let store):
      said = ErrorWords.blocked(store)
    case .refused(let refusal):
      said = ErrorWords.words(for: refusal) ?? ErrorWords.fault
    case .failed:
      said = ErrorWords.fault
    }
    if let said { AccessibilityNotification.Announcement(said).post() }
  }
}

/// A store link of the Edit item sheet: its store, its price in a field, and Remove. VoiceOver reads the field as the
/// store and its price. A link whose price can't be edited shows the price as words, and one that can't be removed
/// has no Remove. At the largest text sizes, the price moves under the store's name.
private struct StoreLinkEditRow: View {
  @Binding var link: ItemEditDraft.StoreLinkEntry
  let remove: () -> Void

  @Environment(\.dynamicTypeSize) private var size

  var body: some View {
    HStack(spacing: 12) {
      let layout =
        size.isAccessibilitySize
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 8))
      layout {
        Text(link.store)
          .accessibilityHidden(link.canEdit)
        if link.canEdit {
          PriceField(priceMinor: $link.priceMinor, currency: link.currency, label: Text(link.store))
        } else {
          Text(price)
            .foregroundStyle(.secondary)
        }
      }
      if link.canDelete {
        Spacer(minLength: 0)
        Button(role: .destructive, action: remove) {
          Text("Remove", bundle: #bundle)
        }
        .buttonStyle(.borderless)
        .accessibilityHint(Text(link.store))
      }
    }
  }

  /// The price, or "no price".
  private var price: String {
    PriceWords.storeLink(priceMinor: link.priceMinor, currency: link.currency)
      ?? String(localized: "no price", bundle: #bundle)
  }
}
