import SwiftUI
import WishboneAPI
import WishboneSession

/// The Edit list sheet: the list's name and description. Save is an unsent change: it shows at once, in every
/// window, and reaches the instance when it answers. See "Edit list" in `docs/screens/list.md`.
///
/// **Provisional.** Plain default: a system form in a sheet, with Cancel and Save in the toolbar. A swipe down
/// doesn't close the sheet while it has typed changes: Cancel asks first.
struct EditListSheet: View {
  let list: ListRow
  let session: SessionModel

  @State private var name: String
  @State private var description: String
  @State private var isConfirmingDiscard = false

  @Environment(\.dismiss) private var dismiss

  init(list: ListRow, session: SessionModel) {
    self.list = list
    self.session = session
    _name = State(initialValue: list.name)
    _description = State(initialValue: list.description ?? "")
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField(text: limited($name, to: SessionModel.listNameLimit), prompt: Text("Name", bundle: #bundle)) {
            Text("Name", bundle: #bundle)
          }
        } header: {
          Text("Name", bundle: #bundle)
        }
        Section {
          TextField(
            text: limited($description, to: SessionModel.listDescriptionLimit),
            prompt: Text("Description", bundle: #bundle), axis: .vertical
          ) {
            Text("Description", bundle: #bundle)
          }
          .lineLimit(3...)
        } header: {
          Text("Description", bundle: #bundle)
        }
      }
      .navigationTitle(Text("Edit list", bundle: #bundle))
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
              await session.editList(list.id, name: name, description: description)
              dismiss()
            }
          } label: {
            Text("Save", bundle: #bundle)
          }
          .keyboardShortcut(.defaultAction)
          .disabled(!hasName)
          .accessibilityHint(
            hasName ? Text("Saves the list.", bundle: #bundle) : Text("Give the list a name.", bundle: #bundle))
        }
      }
    }
  }

  /// Whether the name has a character that isn't a space. A list can't be without one.
  private var hasName: Bool {
    !name.allSatisfy(\.isWhitespace)
  }

  /// Whether the user typed something that isn't saved.
  private var hasChanges: Bool {
    name != list.name || description != (list.description ?? "")
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
