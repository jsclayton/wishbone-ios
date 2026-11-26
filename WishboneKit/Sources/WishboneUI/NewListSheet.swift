import SwiftUI
import WishboneSession

/// The New list form: the name, the description, and For, only when the user has a child whose `can_create_list` is
/// true. For a child, the form says that the child is the recipient and the user is not. Save is an unsent change:
/// the list shows at once, in every window, and its page is pushed. See "The New list form" in
/// `docs/screens/lists.md`, and "A new list for a child" in `docs/spec.md`.
///
/// **Provisional.** Plain default: a system form in a sheet, with Cancel and Save in the toolbar, as Edit list is. A
/// swipe down doesn't close the sheet while it has typed changes: Cancel asks first.
struct NewListSheet: View {
  let session: SessionModel

  /// What Save calls with the new list's stand-in ID, after the sheet closes: the Lists tab pushes the list's page.
  let saved: (String) -> Void

  @State private var draft: NewListDraft
  @State private var isConfirmingDiscard = false
  @State private var isSaving = false

  @Environment(\.dismiss) private var dismiss

  init(session: SessionModel, saved: @escaping (String) -> Void) {
    self.session = session
    self.saved = saved
    _draft = State(initialValue: session.newListDraft())
  }

  var body: some View {
    let choices = session.newListChoices
    NavigationStack {
      Form {
        Section {
          TextField(
            text: limited($draft.name, to: SessionModel.listNameLimit), prompt: Text("Name", bundle: #bundle)
          ) {
            Text("Name", bundle: #bundle)
          }
        } header: {
          Text("Name", bundle: #bundle)
        } footer: {
          // An empty name is said in words, as well as by Save being off.
          if !draft.hasName {
            Text("Give the list a name.", bundle: #bundle)
          }
        }
        Section {
          TextField(
            text: limited($draft.description, to: SessionModel.listDescriptionLimit),
            prompt: Text("Description", bundle: #bundle), axis: .vertical
          ) {
            Text("Description", bundle: #bundle)
          }
          .lineLimit(3...)
        } header: {
          Text("Description", bundle: #bundle)
        }
        if !choices.isEmpty {
          Section {
            Picker(selection: $draft.recipientID) {
              ForEach(choices) { choice in
                choiceName(choice).tag(choice.id)
              }
            } label: {
              Text("For", bundle: #bundle)
            }
          } footer: {
            if let child = choices.first(where: { !$0.isMe && $0.id == draft.recipientID }) {
              Text(
                "\(child.user.name)'s list. You can edit it, but it isn't yours.", bundle: #bundle,
                comment: "The New list form, for a child: the child is the list's recipient, and the user is not")
            }
          }
        }
      }
      .navigationTitle(Text("New list", bundle: #bundle))
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .interactiveDismissDisabled(draft.hasTypedChanges)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            if draft.hasTypedChanges { isConfirmingDiscard = true } else { dismiss() }
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
            save()
          } label: {
            Text("Save", bundle: #bundle)
          }
          .keyboardShortcut(.defaultAction)
          .disabled(!draft.hasName || isSaving)
          .accessibilityHint(
            draft.hasName ? Text("Makes the list.", bundle: #bundle) : Text("Give the list a name.", bundle: #bundle))
        }
      }
    }
  }

  /// The words of a choice of For: "You", or the child's name.
  private func choiceName(_ choice: NewListChoice) -> Text {
    choice.isMe ? Text("You", bundle: #bundle) : Text(choice.user.name)
  }

  /// Save: makes the list, closes the sheet, then pushes the list's page.
  private func save() {
    isSaving = true
    Task {
      let id = await session.createList(draft)
      isSaving = false
      guard let id else { return }
      dismiss()
      saved(id)
    }
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
