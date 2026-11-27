import SwiftUI
import WishboneAPI
import WishboneSession

/// The share extension's screen: the add form, filled in from the one thing that another app shared, with Cancel and
/// Add. See `docs/screens/share-extension.md`, and "The share extension" in `docs/spec.md`.
///
/// It reads the lists that the user can edit while the link or the photo is read, and shows the form when both are in. It shows
/// no claim state, nothing about a gift, and no support row. Nothing waits for later: when the instance can't be
/// reached, it offers Try again and Copy the link, and Cancel keeps nothing.
///
/// **Provisional.** Plain default: the add form as a system form, in the system's share sheet.
public struct ShareExtensionScreen: View {
  let device: ShareDevice

  /// What the other app shared, as the extension's entry point read it. Nil until it is read.
  let shared: SharedReading

  /// Closes the extension. The device has ended first, so nothing is kept.
  let close: @MainActor () -> Void

  /// The progress line, the line when the search gave no form, and the search that runs.
  @State private var state = AddScreenState()

  /// The add form, once the search gave it. It shows when the lists are in too.
  @State private var form: ItemDraft?
  @State private var searching: Task<Void, Never>?

  /// Whether the search ended with a fault, so the screen says so, with Try again.
  @State private var searchFailed = false

  public init(device: ShareDevice, shared: SharedReading, close: @escaping @MainActor () -> Void) {
    self.device = device
    self.shared = shared
    self.close = close
  }

  public var body: some View {
    NavigationStack {
      content
        .toolbar {
          if !showsForm {
            ToolbarItem(placement: .cancellationAction) {
              Button(action: cancel) {
                Text("Cancel", bundle: #bundle)
              }
            }
          }
        }
    }
    .task { await device.load() }
    .task(id: shared) { search() }
  }

  /// The input that the search reads, from the shared thing. Nil for a thing that Wishbone can't use.
  private var input: SearchInput? {
    guard case .read(let thing) = shared else { return nil }
    return thing.flatMap(SearchInput.init(shared:))
  }

  private var showsForm: Bool {
    form != nil && device.state == .ready && device.session != nil
  }

  @ViewBuilder private var content: some View {
    if case .reading = shared {
      progress(nil)
    } else if input == nil {
      message(String(localized: "Wishbone can't add this. Share a link, some text, or a photo.", bundle: #bundle))
    } else {
      switch device.state {
      case .signedOut:
        message(String(localized: "Sign in to Wishbone first.", bundle: #bundle))
      case .appTooOld:
        message(String(localized: "Open Wishbone", bundle: #bundle))
      case .failed:
        List {
          Section {
            Text(ErrorWords.fault)
            tryAgainButton
          }
        }
        .navigationTitle(Text("Add item", bundle: #bundle))
      case .cantReach(let address):
        cantReach(address)
      case .loading:
        progress(readingWords)
      case .ready:
        if let session = device.session, let form {
          AddFormScreen(session: session, draft: form, cancel: cancel) { _ in finish() }
        } else {
          searchLine
        }
      }
    }
  }

  /// The line while the search runs, or why it gave no form.
  @ViewBuilder private var searchLine: some View {
    switch state.phase {
    case .empty where searchFailed:
      List {
        Section {
          Text(ErrorWords.fault)
          tryAgainButton
        }
      }
      .navigationTitle(Text("Add item", bundle: #bundle))
    case .reading, .empty, .unreadablePhoto:
      progress(readingWords)
    case .cantReach:
      if let session = device.session { cantReach(session.session.instance) }
    case .blocked(_, let store):
      List {
        Section {
          Text(ErrorWords.blocked(store))
          Button {
            form = state.addWithoutTheLink()
          } label: {
            Text("Add it without the link", bundle: #bundle)
          }
        }
      }
      .navigationTitle(Text("Add item", bundle: #bundle))
    case .refused(_, let refusal):
      List {
        Section {
          Text(ErrorWords.words(for: refusal) ?? ErrorWords.fault)
          fillItInMyself
        }
      }
      .navigationTitle(Text("Add item", bundle: #bundle))
    }
  }

  /// The progress line, with Fill it in myself while a link or a photo is read.
  private func progress(_ words: String?) -> some View {
    List {
      Section {
        HStack(spacing: 12) {
          ProgressView()
          if let words {
            Text(words)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .accessibilityElement(children: .combine)
        if input != nil, case .reading = state.phase {
          fillItInMyself
        }
      }
    }
    .navigationTitle(Text("Add item", bundle: #bundle))
  }

  /// "Can't reach {address}", with Try again, and Copy the link for a shared link.
  private func cantReach(_ address: InstanceAddress) -> some View {
    List {
      Section {
        Text(CantReach.words(for: address))
        tryAgainButton
        if case .link(let text, _) = input, let link = URL(string: text) {
          CopyTheLinkButton(link: link)
        }
      }
    }
    .navigationTitle(Text("Add item", bundle: #bundle))
  }

  /// A message, with Cancel in the bar.
  private func message(_ words: String) -> some View {
    List {
      Section {
        Text(words)
      }
    }
    .navigationTitle(Text("Add item", bundle: #bundle))
  }

  private var readingWords: String? {
    switch state.phase {
    case .reading(.link(_, let store)): String(localized: "Reading \(store)…", bundle: #bundle)
    case .reading(.photo): String(localized: "Looking at your photo…", bundle: #bundle)
    default: nil
    }
  }

  private var tryAgainButton: some View {
    Button {
      Task { await tryAgain() }
    } label: {
      Text("Try again", bundle: #bundle)
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

  /// Starts the search of the shared thing, once the extension has a session.
  private func search() {
    guard let input, form == nil, device.session != nil, searching == nil || searchFailed else { return }
    run(state.startSearch(input))
  }

  /// Try again: reads the lists again if they weren't read, and the search again if it gave no form.
  private func tryAgain() async {
    if case .cantReach(let input) = state.phase { run(state.startSearch(input)) }
    if searchFailed { search() }
    await device.load()
  }

  private func run(_ started: (id: UUID, input: SearchInput)) {
    guard let session = device.session else { return }
    searching?.cancel()
    searchFailed = false
    searching = Task {
      let outcome = await session.search(started.input)
      if let draft = state.searchEnded(started.id, with: outcome) { form = draft }
      // A fault of the app, or a search that was stopped by the end of the session.
      if outcome == .failed, !Task.isCancelled { searchFailed = true }
    }
  }

  /// Cancel: nothing is kept, and the extension closes.
  private func cancel() {
    searching?.cancel()
    finish()
  }

  private func finish() {
    Task {
      await device.end()
      close()
    }
  }
}

/// Copy the link: puts the shared link on the pasteboard, to add it later from the Add screen.
struct CopyTheLinkButton: View {
  let link: URL

  var body: some View {
    Button {
      Pasteboard.copy(link)
    } label: {
      Text("Copy the link", bundle: #bundle)
    }
  }
}

/// What the other app shared, as the extension reads it from its input items.
public enum SharedReading: Sendable, Equatable {
  /// The items are being read.
  case reading

  /// What was read: one link, one text or one image, or nil for anything else.
  case read(SharedThing?)

  /// Reads the one thing that the input items hold. See `SharedThing.read(_:untitled:)`.
  public static func read(_ items: [NSExtensionItem]) async -> SharedThing? {
    await SharedThing.read(items.flatMap { $0.attachments ?? [] }, untitled: PhotoWords.untitled)
  }
}
