import SwiftUI
import WishboneAPI
import WishboneSession

/// The Add screen: the start of adding an item. See `docs/screens/add.md`, and "Adding an item" in `docs/spec.md`.
///
/// It holds the system search field, Paste, the progress line while a link is read, the line when the instance
/// can't be reached, and the "Added" row after an add. A search pushes the add form. The screen shows nothing from
/// a list, and a link is read on the server, never by the app.
///
/// Take a photo and Choose a photo come later.
///
/// **Provisional.** Plain default: the system search field, and the ways in as rows of a system list under it.
struct AddScreen: View {
  let session: SessionModel

  /// The field's text, the line under it, and the "Added" row. The window keeps it, so the text is still there
  /// after a change of tab.
  @Binding var state: AddScreenState

  @FocusState private var isFieldFocused: Bool

  /// The add form, pushed after a search. It is not restored with the window.
  @State private var form: ItemDraft?

  /// The search that runs. "Fill it in myself" stops it.
  @State private var searching: Task<Void, Never>?

  /// How many items were added here, for the success haptic.
  @State private var adds = 0

  var body: some View {
    List {
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
      }
    }
    .navigationTitle(Text("Add", bundle: #bundle))
    .searchable(text: $state.text, prompt: Text("Paste a link or type what you want", bundle: #bundle))
    .searchFocused($isFieldFocused)
    .onSubmit(of: .search) { search() }
    .onChange(of: state.text) { state.textChanged() }
    .navigationDestination(isPresented: isShowingForm) {
      if let form {
        AddFormScreen(session: session, draft: form) { added in
          state.didAdd(added)
          adds += 1
          self.form = nil
        }
      }
    }
    .sensoryFeedback(.success, trigger: adds)
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
          search()
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
    case .refused:
      Section {
        if let words = words(for: state.phase) {
          Text(words)
        }
        fillItInMyself
      }
    }
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
    searching?.cancel()
    searching = Task {
      let outcome = await session.search(started.input)
      if let draft = state.searchEnded(started.id, with: outcome) {
        form = draft
      }
    }
  }

  private func announce(_ words: String) {
    AccessibilityNotification.Announcement(words).post()
  }
}
