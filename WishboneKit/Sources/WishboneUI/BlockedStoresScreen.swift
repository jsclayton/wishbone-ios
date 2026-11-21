import SwiftUI
import WishboneAPI
import WishboneSession

/// Blocked stores: the stores that the admin keeps out of the instance, pushed from For the admin in Settings. See
/// `docs/screens/blocked-stores.md`.
///
/// The list shows from the local copy. Add and Unblock wait for the server. The list shows only the stores, never
/// the items that link to them.
struct BlockedStoresScreen: View {
  let session: SessionModel

  /// The store whose Unblock waits for the server.
  @State private var unblocking: String?

  /// The words of the last Unblock that didn't work. Nil when there are none to show.
  @State private var message: String?

  /// Whether the Add form is pushed.
  @State private var isAdding = false

  var body: some View {
    List {
      if session.isInstanceUnreachable || message != nil {
        // The primary color: the system's secondary gray is below 4.5:1 on the row.
        Text(message ?? Self.cantReach(session))
      }
      Section {
        if session.blockedStores.isEmpty {
          Text("No stores are blocked.", bundle: #bundle)
        }
        ForEach(session.blockedStores) { store in
          row(store)
        }
      } footer: {
        // The label color itself: the system's secondary gray of a footer is below 4.5:1.
        Text(
          "Links from these stores and their subdomains can't be added or searched. Items that already have them keep them.",
          bundle: #bundle
        )
        .foregroundStyle(Color.primary)
      }
    }
    .navigationTitle(Text("Blocked stores", bundle: #bundle))
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          isAdding = true
        } label: {
          Text("Add", bundle: #bundle)
        }
      }
    }
    .navigationDestination(isPresented: $isAdding) {
      BlockStoreForm(session: session)
    }
  }

  /// A store's row: its name. Unblock is a swipe action, a context menu item, and an accessibility action, so it is
  /// never only a swipe.
  @ViewBuilder
  private func row(_ store: BlockedStoreRow) -> some View {
    let text = Text(store.store)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .trailing) {
        if unblocking == store.id { ProgressView() }
      }
    if store.canDelete {
      text
        .swipeActions {
          unblockButton(store)
        }
        .contextMenu {
          unblockButton(store)
        }
        .accessibilityAction(named: Text("Unblock", bundle: #bundle)) {
          Task { await unblock(store) }
        }
    } else {
      text
    }
  }

  private func unblockButton(_ store: BlockedStoreRow) -> some View {
    // No confirmation, and no destructive role: an unblock is undone with Add, and changes no one's items.
    Button {
      Task { await unblock(store) }
    } label: {
      Text("Unblock", bundle: #bundle)
    }
    .disabled(unblocking != nil)
  }

  private func unblock(_ store: BlockedStoreRow) async {
    guard unblocking == nil else { return }
    unblocking = store.id
    message = nil
    let outcome = await session.unblock(store)
    unblocking = nil
    switch outcome {
    case .unblocked:
      break
    case .unreachable:
      message = Self.cantReach(session)
    case .refused(let refusal):
      message = ErrorWords.words(for: refusal)
    case .failed:
      message = ErrorWords.fault
    }
  }

  static func cantReach(_ session: SessionModel) -> String {
    String(localized: "Can't reach \(session.session.instance.text)", bundle: #bundle)
  }
}

/// Add, in Blocked stores: a form with one field, for a host name or a pasted web address. It is pushed, because
/// Settings is a sheet already. Add waits for the server, and a block goes back to the list.
private struct BlockStoreForm: View {
  let session: SessionModel

  @Environment(\.dismiss) private var dismiss

  @State private var typed = ""
  @State private var isSaving = false
  @State private var outcome: BlockOutcome?

  var body: some View {
    Form {
      Section {
        VStack(alignment: .leading, spacing: 4) {
          // The label is above the field, and hidden from VoiceOver, because the field carries the same words.
          Text("Store to block", bundle: #bundle)
            .accessibilityHidden(true)
          TextField(text: $typed, prompt: Text(String())) {
            Text("Store to block", bundle: #bundle)
          }
          .accessibilityLabel(Text("Store to block", bundle: #bundle))
          #if os(iOS)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .textContentType(.URL)
          #endif
          .autocorrectionDisabled()
          .submitLabel(.done)
          .onSubmit { Task { await add() } }
          .onChange(of: typed) { if outcome == .notAStore { outcome = nil } }
        }
        // A row, not the section's footer: a form draws a footer in the system's secondary gray, which is below
        // 4.5:1. The field shows no placeholder for the same reason.
        if outcome == .notAStore {
          FieldMark(words: Text("Enter a store's address, such as example.com.", bundle: #bundle))
        } else {
          Text("example.com, or paste a link", bundle: #bundle)
            .font(.callout)
        }
      }
      .disabled(isSaving)
      if let message {
        Text(message)
      }
    }
    .navigationTitle(Text("Add", bundle: #bundle))
    .navigationBarBackButtonHidden()
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button {
          dismiss()
        } label: {
          Text("Cancel", bundle: #bundle)
        }
        .disabled(isSaving)
      }
      ToolbarItem(placement: .confirmationAction) {
        Button {
          Task { await add() }
        } label: {
          if isSaving {
            ProgressView()
          } else {
            Text("Add", bundle: #bundle)
          }
        }
        .disabled(isSaving || typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  private func add() async {
    guard !isSaving else { return }
    isSaving = true
    outcome = nil
    let ended = await session.block(typed)
    isSaving = false
    if ended == .blocked {
      dismiss()
    } else {
      outcome = ended
    }
  }

  /// The words of the last Add's outcome, other than the field's mark. Nil when it has none to show.
  private var message: String? {
    switch outcome {
    case nil, .blocked, .notAStore:
      nil
    case .unreachable:
      BlockedStoresScreen.cantReach(session)
    case .refused(let refusal):
      ErrorWords.words(for: refusal)
    case .failed:
      ErrorWords.fault
    }
  }
}
