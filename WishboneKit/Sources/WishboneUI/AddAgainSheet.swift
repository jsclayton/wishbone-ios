import SwiftUI
import WishboneSession

/// The add form that Add again opens, filled from a given gift. See `docs/screens/gift.md` and
/// `docs/screens/add-form.md`.
struct AddAgainForm: Identifiable {
  let id = UUID()
  let draft: ItemDraft
}

extension View {
  /// Add again's sheet: the add form, filled from the given gift, with Cancel. After Add, the sheet closes, and
  /// VoiceOver says where the item went. The Add is an unsent change when the instance can't be reached, so the
  /// item is on its list at once either way. The gift doesn't change.
  func addAgainSheet(_ presented: Binding<AddAgainForm?>, session: SessionModel) -> some View {
    sheet(item: presented) { form in
      NavigationStack {
        AddFormScreen(session: session, draft: form.draft, isInSheet: true) { added in
          presented.wrappedValue = nil
          AccessibilityNotification.Announcement(
            String(localized: "Added \(added.title) to \(added.listName)", bundle: #bundle)
          ).post()
        }
      }
    }
  }
}
