import Foundation
import WishboneAPI
import WishboneSession

/// The words of the one alert, "Some changes couldn't be saved": a line for each late refusal, "{what}: {reason}",
/// with the reason in the app's words for the error code. See "Late refusals" in `docs/spec.md`.
///
/// **Provisional.** The words of each line are drafts.
public enum LateRefusalWords {
  /// The alert's message: a line for each refusal, in the order they came.
  public static func message(_ refusals: [LateRefusal]) -> String {
    refusals.map(line).joined(separator: lineBreak)
  }

  /// What parts the lines: a line break, which shows no words.
  private static let lineBreak = "\n"

  /// One refusal's line: what the change did, then why the server refused it, in the app's words for the code.
  public static func line(_ refusal: LateRefusal) -> String {
    let reason = ErrorWords.words(for: refusal.refusal) ?? ErrorWords.fault
    switch refusal.action {
    case .markBought(_, true):
      return String(
        localized: "Marking \(refusal.title) bought: \(reason)", bundle: #bundle,
        comment: "A late refusal: the item's title, then why the change wasn't saved")
    case .markBought(_, false):
      return String(
        localized: "Marking \(refusal.title) not bought: \(reason)", bundle: #bundle,
        comment: "A late refusal: the item's title, then why the change wasn't saved")
    case .setFromLabel:
      return String(
        localized: "The from label of \(refusal.title): \(reason)", bundle: #bundle,
        comment: "A late refusal: the item's title, then why the change wasn't saved")
    case .setNote:
      return String(
        localized: "The note on \(refusal.title): \(reason)", bundle: #bundle,
        comment: "A late refusal: the item's title, then why the change wasn't saved")
    case .lowerQuantity:
      return String(
        localized: "How many of \(refusal.title): \(reason)", bundle: #bundle,
        comment: "A late refusal: the item's title, then why the change wasn't saved")
    case .unclaim:
      return String(
        localized: "I won't get \(refusal.title): \(reason)", bundle: #bundle,
        comment: "A late refusal of I won't get this: the item's title, then why the change wasn't saved")
    case .acknowledge(_, "removed"):
      return String(
        localized: "Keeping \(refusal.title): \(reason)", bundle: #bundle,
        comment: "A late refusal of Keep it: the item's title, then why the change wasn't saved")
    case .acknowledge:
      return String(
        localized: "The change to \(refusal.title): \(reason)", bundle: #bundle,
        comment: "A late refusal of OK on a gift's flag: the item's title, then why the change wasn't saved")
    }
  }
}
