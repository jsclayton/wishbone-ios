import PhotosUI
import SwiftUI
import WishboneAPI
import WishboneSession

#if os(iOS)
  import AVFoundation
#endif

/// The Add screen: the start of adding an item. See `docs/screens/add.md`, and "Adding an item" in `docs/spec.md`.
///
/// It holds the system search field, Paste, Take a photo and Choose a photo, the progress line while a link or a
/// photo is read, the line when the instance can't be reached, and the "Added" row after an add. A search pushes the
/// add form. The screen shows nothing from a list, and a link is read on the server, never by the app. A photo goes
/// only to the instance.
///
/// In a list's sheet, the screen is fixed to that list: a line names the list, Cancel closes the sheet, and after Add
/// the sheet closes.
///
/// **Provisional.** Plain default: the system search field, and the ways in as rows of a system list under it.
struct AddScreen: View {
  let session: SessionModel

  /// The field's text, the line under it, and the "Added" row. The window keeps it, so the text is still there
  /// after a change of tab.
  @Binding var state: AddScreenState

  /// Closes the sheet, when the screen is in a list's sheet. Nil in the screen's place.
  var close: (() -> Void)?

  @FocusState private var isFieldFocused: Bool

  /// The add form, pushed after a search. It is not restored with the window.
  @State private var form: ItemDraft?

  /// The search that runs. "Fill it in myself" stops it.
  @State private var searching: Task<Void, Never>?

  /// How many items were added here, for the success haptic.
  @State private var adds = 0

  @State private var isChoosingPhoto = false
  @State private var chosenPhoto: PhotosPickerItem?

  #if os(iOS)
    /// Whether Take a photo can open the camera. It is read again each time the app comes back, as from Settings.
    @State private var camera = CameraAccess.forPhotos
    @State private var isTakingPhoto = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
  #endif

  var body: some View {
    List {
      // The line that names the list is first, so VoiceOver reads it before the ways in.
      if let listID = state.fixedListID, let target = session.target(ofList: listID) {
        Section {
          Text("Adding to \(AddTargetName.words(for: target))", bundle: #bundle)
        }
      }
      if let added = state.added {
        Section {
          // It pushes the item's page on this tab's stack.
          NavigationLink(value: Page.item(id: added.id)) {
            Text("Added \(added.title) to \(added.listName)", bundle: #bundle)
          }
        } footer: {
          if added.imageWasLeftOut {
            Text(ErrorWords.imageLeftOut)
          }
        }
      }
      line
      Section {
        PasteButton(payloadType: String.self) { strings in
          guard let text = strings.first else { return }
          Task { @MainActor in
            state.text = text
            search()
          }
        }
        .labelStyle(.titleAndIcon)
        takeAPhoto
        Button {
          isChoosingPhoto = true
        } label: {
          Label {
            Text("Choose a photo", bundle: #bundle)
          } icon: {
            Image(systemName: "photo.on.rectangle")
          }
        }
      } footer: {
        #if os(iOS)
          if let reason = camera.photoReason {
            Text(reason)
          }
        #endif
      }
      #if os(iOS)
        if camera.offersSettings {
          Section {
            Button {
              if let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) }
            } label: {
              Text("Open Settings", bundle: #bundle)
            }
          }
        }
      #endif
    }
    .navigationTitle(Text("Add", bundle: #bundle))
    .searchable(text: $state.text, prompt: Text("Paste a link or type what you want", bundle: #bundle))
    .searchFocused($isFieldFocused)
    .onSubmit(of: .search) { search() }
    .onChange(of: state.text) { state.textChanged() }
    .navigationDestination(isPresented: isShowingForm) {
      if let form {
        AddFormScreen(session: session, draft: form) { added in
          if let close {
            close()
            return
          }
          state.didAdd(added)
          adds += 1
          self.form = nil
        }
      }
    }
    .toolbar {
      if let close {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            searching?.cancel()
            close()
          } label: {
            Text("Cancel", bundle: #bundle)
          }
        }
      }
    }
    .sensoryFeedback(.success, trigger: adds)
    // The system photo picker runs outside the app: it needs no photo library permission.
    .photosPicker(isPresented: $isChoosingPhoto, selection: $chosenPhoto, matching: .images)
    .task(id: chosenPhoto) { await searchChosenPhoto() }
    #if os(iOS)
      .fullScreenCover(isPresented: $isTakingPhoto) {
        CameraPicker { taken in
          // The camera's photo has no file yet. The JPEG at full quality keeps its orientation for the encoder.
          guard let file = taken.jpegData(compressionQuality: 1) else { return }
          Task { search(await Self.photo(of: file)) }
        }
        .ignoresSafeArea()
      }
      .onChange(of: scenePhase) {
        if scenePhase == .active { camera = .forPhotos }
      }
    #endif
    // The screen opens with its field ready, when it is empty. Back from the form, with the text still in the
    // field, and the screen after an add, with its "Added" row, open with no keyboard. Where the system shows the
    // field as a button, in a tab bar at the top of a wide window, the field opens with a tap on that button.
    .onAppear { isFieldFocused = form == nil && state.text.isEmpty && state.added == nil }
    // The "Added" row stays until the user leaves the screen: another tab, or a page pushed over it.
    .onDisappear {
      if form == nil { state.left() }
    }
    .onChange(of: state.added) { _, added in
      guard let added else { return }
      let words = String(localized: "Added \(added.title) to \(added.listName)", bundle: #bundle)
      announce(added.imageWasLeftOut ? "\(words). \(ErrorWords.imageLeftOut)" : words)
    }
    .onChange(of: state.phase) { _, phase in
      if let words = words(for: phase) { announce(words) }
    }
  }

  /// The line under the field: the progress line while a search runs, or why it gave no form.
  @ViewBuilder private var line: some View {
    switch state.phase {
    case .empty:
      EmptyView()
    case .reading:
      Section {
        HStack(spacing: 12) {
          ProgressView()
          if let words = words(for: state.phase) {
            Text(words)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .accessibilityElement(children: .combine)
        fillItInMyself
      }
    case .cantReach:
      Section {
        Text(CantReach.words(for: session.session.instance))
        Button {
          tryAgain()
        } label: {
          Text("Try again", bundle: #bundle)
        }
        fillItInMyself
      }
    case .blocked:
      Section {
        if let words = words(for: state.phase) {
          Text(words)
        }
        Button {
          form = state.addWithoutTheLink()
        } label: {
          Text("Add it without the link", bundle: #bundle)
        }
      }
    case .refused(let input, let refusal):
      Section {
        if let words = words(for: state.phase) {
          Text(words)
        }
        // A photo that the server can't use can't be the item's image either: the words say to choose another.
        if !(input.isPhoto && refusal.code.isAboutTheImage) {
          fillItInMyself
        }
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
          Label {
            Text("Take a photo", bundle: #bundle)
          } icon: {
            Image(systemName: "camera")
          }
        }
        .disabled(camera != .allowed)
      }
    #endif
  }

  private var fillItInMyself: some View {
    Button {
      searching?.cancel()
      searching = nil
      form = state.fillItInMyself()
    } label: {
      Text("Fill it in myself", bundle: #bundle)
    }
  }

  /// The words of the line, for the screen and for VoiceOver.
  private func words(for phase: AddScreenState.Phase) -> String? {
    switch phase {
    case .empty:
      return nil
    case .reading(.link(_, let store)):
      return String(localized: "Reading \(store)…", bundle: #bundle)
    case .reading(.words):
      return nil
    case .reading(.photo):
      return String(localized: "Looking at your photo…", bundle: #bundle)
    case .cantReach:
      return CantReach.words(for: session.session.instance)
    case .blocked(_, let store):
      return ErrorWords.blocked(store)
    case .refused(_, let refusal):
      return ErrorWords.words(for: refusal)
    }
  }

  private var isShowingForm: Binding<Bool> {
    Binding {
      form != nil
    } set: { isShowing in
      if !isShowing { form = nil }
    }
  }

  /// Searches the field's text, and pushes the form with what the search found.
  private func search() {
    guard let started = state.startSearch() else { return }
    run(started)
  }

  /// Searches a photo that the user took or chose. The text in the field stays.
  private func search(_ photo: Photo) {
    run(state.startSearch(.photo(photo)))
  }

  /// Try again, after the instance couldn't be reached: the same link, words, or photo.
  private func tryAgain() {
    guard case .cantReach(let input) = state.phase else { return }
    run(state.startSearch(input))
  }

  private func run(_ started: (id: UUID, input: SearchInput)) {
    searching?.cancel()
    searching = Task {
      let outcome = await session.search(started.input)
      if let draft = state.searchEnded(started.id, with: outcome) {
        form = draft
      }
    }
  }

  /// Searches the photo that the user chose in the system photo picker. A photo that can't be loaded changes
  /// nothing.
  private func searchChosenPhoto() async {
    guard let chosenPhoto else { return }
    defer { self.chosenPhoto = nil }
    guard let file = try? await chosenPhoto.loadTransferable(type: Data.self) else { return }
    search(await Self.photo(of: file))
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

  /// The photo of the file, as a JPEG under the server's limit, made away from the main actor. Its title, when no
  /// guess comes back, names the day it was taken.
  @concurrent nonisolated private static func photo(of file: Data) async -> Photo {
    Photo(file: file) { date in
      String(localized: "Photo from \(date.formatted(date: .abbreviated, time: .omitted))", bundle: #bundle)
    }
  }

  private func announce(_ words: String) {
    AccessibilityNotification.Announcement(words).post()
  }
}

extension ErrorCode {
  /// Whether the server refused the file itself: too large, or not an image.
  fileprivate var isAboutTheImage: Bool {
    switch self {
    case .imageTooLarge, .requestTooLarge, .imageInvalid: true
    default: false
    }
  }
}
