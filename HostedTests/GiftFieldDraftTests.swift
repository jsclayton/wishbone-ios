import Foundation
import Testing
import WishboneUI

/// A gift's From and Note fields: each saves once when it loses its editing, and then shows the text as it is saved.
/// See "Set the from label" and "Write the note" in `docs/screens/gift.md`.
@Suite("A gift's text fields", .timeLimit(.minutes(1)))
struct GiftFieldDraftTests {
  @Test("One focus loss and a close of the page save one change, in either order")
  func savesOnce() {
    // The focus goes, then the page closes.
    var draft = GiftFieldDraft(.note, saved: "")
    draft.began()
    draft.text = "The blue one"
    var saves = [draft.ended(), draft.ended()].compactMap(\.self)
    #expect(saves == ["The blue one"])

    // The page closes first, then the focus goes: the close saves, and the focus change doesn't.
    draft.began()
    draft.text = "The red one"
    saves = [draft.ended(), draft.ended()].compactMap(\.self)
    #expect(saves == ["The red one"])

    // A field that never had focus saves nothing when its page closes.
    var untouched = GiftFieldDraft(.fromLabel, saved: "Emma")
    #expect(untouched.ended() == nil)
    #expect(untouched.text == "Emma")
  }

  @Test("After a save, the field shows the text as it is saved")
  func showsSaved() {
    var draft = GiftFieldDraft(.fromLabel, saved: "Emma")
    draft.began()
    draft.text = "  Emma  "
    #expect(draft.ended() == "  Emma  ")
    #expect(draft.text == "Emma")

    var note = GiftFieldDraft(.note, saved: "Blue")
    note.began()
    note.text = " \n "
    #expect(note.ended() == " \n ")
    #expect(note.text == "")
  }

  @Test("A change saved in another window shows only while the field isn't edited")
  func savedElsewhere() {
    var draft = GiftFieldDraft(.fromLabel, saved: "Emma")
    draft.began()
    draft.text = "Em"
    draft.savedChanged(to: "Sam")
    #expect(draft.text == "Em")
    #expect(draft.ended() == "Em")
    draft.savedChanged(to: "Sam")
    #expect(draft.text == "Sam")

    // Another gift: its text shows, and no edit is left to save.
    draft.began()
    draft.reset(to: "Alex")
    #expect(draft.text == "Alex")
    #expect(draft.ended() == nil)
  }

  @Test("The from label stops at 60 characters and the note at 2000, as the server counts them")
  func limits() {
    var label = GiftFieldDraft(.fromLabel, saved: "")
    label.text = String(repeating: "x", count: 70)
    #expect(label.text == String(repeating: "x", count: 60))
    var note = GiftFieldDraft(.note, saved: "")
    note.text = String(repeating: "é", count: 2001)
    #expect(note.text == String(repeating: "é", count: 2000))
  }
}
