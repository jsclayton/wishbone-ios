import Foundation
import WishboneAPI

/// The app's own words for each error code of the API. See "Words for error codes" in
/// `docs/screens/README.md`, which holds the table. The app never shows the server's `detail` for a code that it
/// knows.
enum ErrorWords {
  /// The words for a refusal. For a code that the app doesn't know, they are the server's `detail`.
  static func words(for refusal: APIError.Refusal) -> String {
    switch refusal.code {
    case .loginLinkInvalid:
      linkInvalid
    case .rateLimited:
      String(localized: "Too many tries. Wait a minute, then try again.", bundle: #bundle)
    case .invalidInput:
      String(localized: "Some fields need another look.", bundle: #bundle)
    case .notFound:
      String(localized: "This is gone, or it isn't shared with you.", bundle: #bundle)
    case .unknownFilter, .unknownSort, .cursorMismatch:
      fault
    case .unauthorized, .apiVersionRemoved, .unknown:
      // The first two have screens of their own, and reach here only in an answer that those screens don't take.
      refusal.detail
    }
  }

  /// The words for a login link that is used or expired. The server gives one answer for both.
  static var linkInvalid: String {
    String(localized: "That link was already used, or it has expired. Ask for a new one.", bundle: #bundle)
  }

  /// The words for a fault of the app: a code that only a fault can cause, or an answer that the app can't read.
  static var fault: String {
    String(localized: "Something went wrong in Wishbone. Try again.", bundle: #bundle)
  }
}
