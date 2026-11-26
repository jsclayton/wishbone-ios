import SwiftUI
import WishboneAPI
import WishboneSession

/// A list's own Add item row, under its items on the list's page and on a person's page, from the list's `can_edit`.
/// It opens the Add screen in a sheet, fixed to the list, so a person can add several items to one list. See "The
/// add form is pushed onto the Add screen" and "Which list" in `docs/spec.md`, and `docs/screens/list.md`.
struct AddItemRow: View {
  let session: SessionModel
  let listID: String

  @State private var isAdding = false

  var body: some View {
    Button {
      isAdding = true
    } label: {
      Label {
        Text("Add item", bundle: #bundle)
      } icon: {
        Image(systemName: "plus")
      }
    }
    .sheet(isPresented: $isAdding) {
      AddSheet(session: session, listID: listID)
    }
  }
}

/// The Add screen in a sheet, fixed to a list. The form is pushed inside the sheet, so there is never a sheet on a
/// sheet. After Add, the sheet closes, and the item is at the end of the list. See `docs/screens/add.md`.
private struct AddSheet: View {
  let session: SessionModel

  /// The field's text and the line under it. Each sheet starts empty.
  @State private var state: AddScreenState

  @Environment(\.dismiss) private var dismiss

  init(session: SessionModel, listID: String) {
    self.session = session
    _state = State(initialValue: AddScreenState(fixedTo: listID))
  }

  var body: some View {
    NavigationStack {
      AddScreen(session: session, state: $state, close: { dismiss() })
    }
  }
}

/// A list as a target of an add: its name, and its recipients' names when the user is not one, "Lego · Emma". Add to
/// and the line "Adding to {list}" show it. See "Whose list: name the recipient" in `docs/spec.md`.
struct AddTargetName: View {
  let target: AddTo.Target

  var body: some View {
    Text(Self.words(for: target))
  }

  static func words(for target: AddTo.Target) -> String {
    guard !target.recipientNames.isEmpty else { return target.list.name }
    let names = target.recipientNames.formatted(.list(type: .and))
    return String(localized: "\(target.list.name) · \(names)", bundle: #bundle)
  }
}
