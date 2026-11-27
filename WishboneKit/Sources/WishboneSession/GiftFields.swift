import Foundation
import WishboneAPI

// The fields that a giver changes on a gift's page: the from label, the note, and how many. See "Set the from label",
// "Write the note" and "Change how many" in `docs/screens/gift.md`, and "Unsent changes" and "Claims are online only"
// in `docs/spec.md`.
//
// - The from label, the note, and lowering how many are unsent changes: each shows at once, in every window, and
//   reaches the instance when it answers.
// - Raising how many is a claim, and never an unsent change. It waits for the server's answer. With no connection,
//   nothing changes and nothing waits to be sent.
//
// **The note and the bought mark are the giver's alone.** The server sends them only to the giver. Nothing here goes
// to a system surface or into the shared container.

/// The rules of a gift's text fields, as the server has them: it trims the ends, an empty text clears the field, and
/// it counts characters as Unicode scalars.
public enum GiftText {
  /// The longest from label, in characters.
  public static let fromLabelLimit = 60

  /// The longest note, in characters.
  public static let noteLimit = 2000

  /// The from label as the server keeps it: trimmed, at most 60 characters, and nil when empty.
  public static func fromLabel(_ text: String) -> String? {
    cleaned(text, limit: fromLabelLimit)
  }

  /// The note as the server keeps it: trimmed, at most 2000 characters, and nil when empty.
  public static func note(_ text: String) -> String? {
    cleaned(text, limit: noteLimit)
  }

  /// The text cut to at most `limit` characters, as the server counts them, without splitting a character that
  /// shows as one (an emoji of several scalars goes whole, or not at all).
  public static func cut(_ text: String, to limit: Int) -> String {
    guard text.unicodeScalars.count > limit else { return text }
    var cut = Substring(text)
    while cut.unicodeScalars.count > limit { cut.removeLast() }
    return String(cut)
  }

  private static func cleaned(_ text: String, limit: Int) -> String? {
    let trimmed = cut(text.trimmingCharacters(in: .whitespacesAndNewlines), to: limit)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// How a raise of a gift's quantity ended. See "Raising how many" in `docs/screens/gift.md`.
///
/// **No outcome says who else claimed.**
public enum RaiseOutcome: Sendable, Equatable {
  /// The server granted the raise. The copy has the new number.
  case raised

  /// The gift can't be raised: the copy's gift is not the giver's open gift, or its `can_raise_quantity` is false.
  /// Nothing was sent.
  case notOffered

  /// No more are wanted (409 `item_fully_claimed`). The number stays.
  case someoneElseGotIt

  /// The instance can't be reached. The number stays, and nothing waits to be sent.
  case unreachable

  /// The server refused the raise for another reason, such as `quantity_raise_not_allowed` for a giver who is now
  /// a recipient of the list. The number stays.
  case refused(APIError.Refusal)

  /// A fault of the app, such as an answer that it can't read, or a session that ended.
  case failed
}

extension SessionModel {
  /// Set the from label: who the gift is from, when that isn't only the giver, as an unsent change. The text is kept
  /// as the server keeps it: trimmed, at most 60 characters, and an empty one clears the label.
  ///
  /// It does nothing for a gift that the copy doesn't hold, that the giver can't edit, or whose label is already
  /// that. It returns when the change is in the journal and published, and doesn't wait for the sync.
  public func setFromLabel(gift id: String, _ text: String) async {
    let fromLabel = GiftText.fromLabel(text)
    guard let gift = editableGift(id), gift.fromLabel.flatMap(GiftText.fromLabel) != fromLabel else { return }
    await record(.setFromLabel(giftID: id, fromLabel: fromLabel), title: gift.title)
  }

  /// Write the note: the giver's private note, as an unsent change. The text is kept as the server keeps it: trimmed,
  /// at most 2000 characters, and an empty one clears the note.
  ///
  /// It does nothing for a gift that the copy doesn't hold, that the giver can't edit, or whose note is already that.
  public func setNote(gift id: String, _ text: String) async {
    let note = GiftText.note(text)
    guard let gift = editableGift(id), gift.note.value.flatMap(GiftText.note) != note else { return }
    await record(.setNote(giftID: id, note: note), title: gift.title)
  }

  /// Lower how many, as an unsent change. It shows at once, and a sync sends it.
  ///
  /// It does nothing for a number that is not lower than the gift's now, or less than 1. A raise is `raiseQuantity`.
  public func lowerQuantity(gift id: String, to quantity: Int) async {
    guard let gift = editableGift(id), quantity >= 1, quantity < gift.quantity else { return }
    await record(.lowerQuantity(giftID: id, quantity: quantity), title: gift.title)
  }

  /// Raise how many by one, with `PATCH /gifts/{id}`. A raise is a claim: it waits for the server's answer, and is
  /// never an unsent change. See "Claims are online only" in `docs/spec.md`.
  ///
  /// A lower of the same gift that waits is sent first, by a sync, so the raise lands after it. On success, the gift as the
  /// server has it now and the item's new numbers go into the copy in one change, and the session model publishes
  /// them before it returns.
  ///
  /// Diagnostics: never here. A refused raise is a 403 or a 409, which the client doesn't capture.
  public func raiseQuantity(gift id: String) async -> RaiseOutcome {
    guard let gift = editableGift(id), offersRaise(onGift: gift) else { return .notOffered }
    do {
      if try await database.hasUnsentQuantityChange(toGift: id) {
        // A sync sends it: the unsent changes go only as the first step of a sync. A sync that runs now may be past
        // its sends, so this one runs after it.
        let outcome = await syncNow()
        guard !(try await database.hasUnsentQuantityChange(toGift: id)) else {
          return outcome == .unreachable ? .unreachable : .failed
        }
      }
      // The number as the server has it, now that no lower of it waits.
      guard let now = self.gift(id: id) else { return .failed }
      let answer = try await client.updateGift(id, GiftChanges(quantity: now.quantity + 1), key: UUID().uuidString)
      // The item's new numbers. Without them, the gift is saved alone, and the next sync brings the item.
      let item = try? await client.item(gift.itemID)
      guard !hasEnded else { return .failed }
      try await database.saveClaim([answer], item: item)
      // A sync that runs now may have asked before the raise. Its pull keeps the number, and one more sync asks after it.
      syncAgainIfSyncing()
      await publishNow()
      return .raised
    } catch APIError.refused(let refusal) where refusal.code == .itemFullyClaimed {
      return .someoneElseGotIt
    } catch let error as APIError {
      if let refusal = await outcome(of: error) { return .refused(refusal) }
      if case .unreachable = error { return .unreachable }
      return .failed
    } catch is CancellationError {
      return .failed
    } catch {
      Log.fault(.session, "The copy can't take the raise.", detail: "\(error)")
      return .failed
    }
  }

  /// Whether How many can go higher: the gift's `can_raise_quantity`, and the giver is not a recipient of its list,
  /// as the copy shows the list. An accept that waits to be sent counts: once a giver is a recipient, how many can
  /// only go down, and the gift's `can_raise_quantity` is the giver's until the next pull.
  func offersRaise(onGift gift: GiftRow) -> Bool {
    gift.canRaiseQuantity && !isRecipient(ofList: gift.listID)
  }

  /// The giver's open gift that they can edit, from the copy. Nil for the rest.
  private func editableGift(_ id: String) -> GiftRow? {
    guard !hasEnded, let gift = gift(id: id), gift.state == .open, gift.canEdit else { return nil }
    return gift
  }
}
