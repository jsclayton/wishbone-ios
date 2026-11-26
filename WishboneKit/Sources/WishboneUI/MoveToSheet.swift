import SwiftUI
import WishboneSession

/// Move to…: a picker of the other lists that the user can edit, in a sheet, each with its recipients' names when
/// the user is not one, and a child's lists under the child's name. A tap moves the item to the end of that list, at
/// once, in every window, and closes the sheet. Nothing asks first, and nothing here says a word about gifts. See
/// "Every drag has a way without dragging" in `docs/spec.md`, and Move to… in `docs/screens/item.md`.
///
/// **Provisional.** Plain default: a system list in a sheet, with Cancel in the toolbar.
struct MoveToSheet: View {
  let itemID: String
  let session: SessionModel

  @Environment(\.dismiss) private var dismiss
  @Environment(\.foregroundWindow) private var window

  var body: some View {
    NavigationStack {
      List {
        if let targets = session.moveTargets(ofItem: itemID) {
          Section {
            ForEach(targets.yourLists) { target in
              row(target)
            }
          }
          ForEach(targets.children) { part in
            Section {
              ForEach(part.targets) { target in
                row(target)
              }
            } header: {
              MoveToChildHeading(name: part.child.name)
            }
          }
        }
      }
      .navigationTitle(Text("Move to…", bundle: #bundle))
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            dismiss()
          } label: {
            Text("Cancel", bundle: #bundle)
          }
        }
      }
    }
  }

  private func row(_ target: AddTo.Target) -> some View {
    Button {
      Task {
        await session.moveItem(itemID, toList: target.id, from: window)
        dismiss()
      }
    } label: {
      // In the primary color, as a system picker's rows are: each is a choice, not a link.
      AddTargetName(target: target)
        .foregroundStyle(.primary)
    }
  }
}

/// A child's part of the picker: the child's name, as the Lists tab heads it. A bare `Text` as a section's header
/// takes the system's grey, below 4.5:1, so the heading is plain text in the primary color, and a heading for the
/// VoiceOver rotor.
private struct MoveToChildHeading: View {
  let name: String

  var body: some View {
    VStack(alignment: .leading) {
      Text(name)
    }
    .font(.headline)
    .foregroundStyle(.primary)
    .textCase(nil)
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

/// Move to…, in an item's row's context menu and its page's menu. It opens the Move to… sheet.
struct MoveToButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label {
        Text("Move to…", bundle: #bundle)
      } icon: {
        Image(systemName: "folder")
      }
    }
  }
}
