import Foundation
import WishboneSession

/// What a gift's From or Note field shows, and when it saves. See "Set the from label" and "Write the note" in
/// `docs/screens/gift.md`.
///
/// - The field saves once each time it loses its editing: when its focus goes, or when the page closes while it has
///   focus. SwiftUI can report both for one close, in either order, and only the first one saves.
/// - After a save, the field shows the text as the server keeps it: trimmed, and cut to the limit.
/// - While it is edited, it keeps what the giver types. Otherwise it shows what is saved, so a change from another
///   window shows here.
public struct GiftFieldDraft: Sendable, Equatable {
  /// Which field of the gift.
  public enum Field: Sendable, Equatable {
    case fromLabel, note
  }

  public let field: Field

  /// The text that the field shows. It stops at the field's limit, as the server counts characters.
  public var text: String {
    didSet {
      let cut = GiftText.cut(text, to: limit)
      if cut != text { text = cut }
    }
  }

  /// True from when the field gets focus until its text is saved.
  public private(set) var isEditing = false

  public init(_ field: Field, saved: String) {
    self.field = field
    self.text = GiftText.cut(saved, to: Self.limit(of: field))
  }

  /// The longest text of the field, in characters: 60 for the from label, 2000 for the note.
  public var limit: Int { Self.limit(of: field) }

  /// The field got focus.
  public mutating func began() {
    isEditing = true
  }

  /// The field's focus went, or the page closed. Returns the text to save, or nil when the field was not being
  /// edited, or when this edit was already saved. The field then shows the text as it is saved.
  public mutating func ended() -> String? {
    guard isEditing else { return nil }
    isEditing = false
    let typed = text
    text = kept(typed)
    return typed
  }

  /// The saved text is now `saved`, from this window or another. The field shows it unless it is being edited.
  public mutating func savedChanged(to saved: String) {
    guard !isEditing else { return }
    text = saved
  }

  /// The field now shows another gift: it shows that gift's saved text, and no edit is left.
  public mutating func reset(to saved: String) {
    isEditing = false
    text = saved
  }

  private func kept(_ text: String) -> String {
    switch field {
    case .fromLabel: GiftText.fromLabel(text) ?? ""
    case .note: GiftText.note(text) ?? ""
    }
  }

  private static func limit(of field: Field) -> Int {
    switch field {
    case .fromLabel: GiftText.fromLabelLimit
    case .note: GiftText.noteLimit
    }
  }
}
