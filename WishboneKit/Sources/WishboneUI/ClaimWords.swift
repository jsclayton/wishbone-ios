import Foundation
import WishboneAPI
import WishboneSession

/// The words of I'll get this: the line of a giver's own gift on an item, and what a claim that didn't end in a gift
/// says. See "Words" in `docs/screens/item.md`, and "Words for error codes" in `docs/screens/README.md`.
///
/// **No words say who else claimed.**
public enum ClaimWords {
  /// "You claimed 1 for Christmas", or "You claimed 1 · hidden until Mar 4" when the giver can't see the occasion.
  public static func line(_ claim: ItemPage.ClaimLine) -> String {
    switch claim.occasion {
    case .named(let name):
      return String(localized: "You claimed \(claim.quantity) for \(name)", bundle: #bundle)
    case .hiddenUntil(let date):
      let day = date.formatted(.dateTime.month(.abbreviated).day())
      return String(localized: "You claimed \(claim.quantity) · hidden until \(day)", bundle: #bundle)
    }
  }

  /// What a claim that made no gift says, in place. Nil for a claim that the server granted: the gift's line says
  /// it.
  ///
  /// `recipients` are the list's recipients, so the words for `user_deactivated` name the one that is deactivated.
  public static func result(
    of outcome: ClaimOutcome,
    address: InstanceAddress,
    recipients: [UserRow]
  ) -> String? {
    switch outcome {
    case .claimed:
      return nil
    case .someoneElseGotIt:
      return ErrorWords.someoneElseGotIt
    case .unreachable:
      return String(localized: "Can't reach \(address.text). Nothing was claimed.", bundle: #bundle)
    case .refused(let refusal) where refusal.code == .userDeactivated:
      let deactivated = recipients.first(where: \.isDeactivated) ?? recipients.first
      return deactivated.map { ErrorWords.deactivated($0.name) } ?? refusal.detail
    case .refused(let refusal):
      return ErrorWords.words(for: refusal) ?? ErrorWords.fault
    case .failed:
      return ErrorWords.fault
    }
  }
}
