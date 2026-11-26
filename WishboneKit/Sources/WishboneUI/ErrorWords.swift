import Foundation
import WishboneAPI

/// The app's own words for each error code of the API: the one lookup that every screen uses. See "Words for
/// error codes" in `docs/screens/README.md`, which holds the table. The app never shows the server's `detail` for a
/// code that it knows.
///
/// Each ticket adds the codes that its screens meet.
public enum ErrorWords {
  /// The words of `too_many_images`, which the Edit item sheet also shows when the item has 5 photos.
  static var tooManyImages: String {
    String(localized: "An item can have 5 photos.", bundle: #bundle)
  }

  /// The words of `too_many_store_links`, which the Edit item sheet also shows when the item has 10 store links.
  static var tooManyStoreLinks: String {
    String(localized: "An item can have 10 store links.", bundle: #bundle)
  }

  /// The words for a refusal. Nil for a code that counts as success, which shows nothing. For a code that the app
  /// doesn't know, they are the server's `detail`.
  public static func words(for refusal: APIError.Refusal) -> String? {
    if refusal.code.isSuccess { return nil }
    switch refusal.code {
    case .loginLinkInvalid:
      return linkInvalid
    // The hourly limit of reading links and photos: a search, Add link, and Refresh prices each read a store's page.
    case .rateLimited where [.search, .addStoreLink, .refreshPrices].contains(refusal.route):
      return String(localized: "You've read 30 links and photos in the last hour. Try again later.", bundle: #bundle)
    case .rateLimited:
      return String(localized: "Too many tries. Wait a minute, then try again.", bundle: #bundle)
    case .imageFetchFailed:
      return imageLeftOut
    case .tooManyImages:
      return tooManyImages
    case .tooManyStoreLinks:
      return tooManyStoreLinks
    case .invalidInput:
      return String(localized: "Some fields need another look.", bundle: #bundle)
    case .notFound, .referenceNotFound:
      return String(localized: "This is gone, or it isn't shared with you.", bundle: #bundle)
    case .forbidden, .fieldNotWritable:
      return String(localized: "You can't do this any more.", bundle: #bundle)
    case .requestTooLarge, .imageTooLarge:
      return String(localized: "That photo is too large. Choose a smaller one.", bundle: #bundle)
    case .imageInvalid:
      return notAnImage
    case .birthdayRequired:
      return String(localized: "A birthday is required.", bundle: #bundle)
    case .adminHasNoParents:
      return String(localized: "The admin can't have parents.", bundle: #bundle)
    case .itemFullyClaimed:
      return someoneElseGotIt
    case .recipientCannotClaim:
      return String(localized: "You can't claim on a list that is for you.", bundle: #bundle)
    case .quantityRaiseNotAllowed:
      return String(
        localized: "You can only lower how many, because this list is now for you too.", bundle: #bundle)
    case .occasionNotAllowed:
      return String(localized: "That occasion can't be used for this gift. Pick another.", bundle: #bundle)
    case .occasionLocked:
      return String(localized: "The occasion for this gift can't be changed.", bundle: #bundle)
    case .giftGiven:
      return String(localized: "This gift was already given.", bundle: #bundle)
    case .primaryList:
      return String(localized: "You can't do this to a primary list.", bundle: #bundle)
    case .unknownFilter, .unknownSort, .cursorMismatch, .imageAttached, .resourceChanged:
      return fault
    case .unauthorized, .apiVersionRemoved, .userDeactivated, .lastRecipient, .listHasOtherRecipients, .parentLoop,
      .storeBlocked, .unknown:
      // The first two have screens of their own, and reach here only in an answer that those screens don't take.
      // `user_deactivated` names a person, `last_recipient` and `list_has_other_recipients` a list, and
      // `store_blocked` a store, so the screen that meets each gives its words (see `lastRecipient(of:)` and
      // `otherRecipients(of:)`). `parent_loop` shows the server's `detail`, as the
      // table says.
      return refusal.detail
    case .alreadyClaimed, .alreadyInvited, .alreadyRecipient, .alreadyInGroup, .alreadyAttached, .alreadyBlocked:
      // These count as success: see above.
      return nil
    }
  }

  /// The words for a file that isn't an image that Wishbone can use: `image_invalid`. A photo that the device
  /// itself can't read gets them too, with nothing sent.
  public static var notAnImage: String {
    String(localized: "Wishbone can't use that file. Choose a JPEG, PNG, GIF, or WebP photo.", bundle: #bundle)
  }

  /// The words for an item added without a picture that the server couldn't save: `image_fetch_failed`.
  public static var imageLeftOut: String {
    String(localized: "One picture couldn't be saved, so the item was added without it.", bundle: #bundle)
  }

  /// The words for a link from a blocked store: `store_blocked`.
  public static func blocked(_ store: String) -> String {
    String(localized: "Links from \(store) are blocked on this Wishbone.", bundle: #bundle)
  }

  /// The words for a claim that came after the last one: `item_fully_claimed`. The words never say who got it.
  public static var someoneElseGotIt: String {
    String(localized: "Someone else just got this.", bundle: #bundle)
  }

  /// The words for `last_recipient`: the user is the list's only recipient, so they can't leave it.
  public static func lastRecipient(of list: String) -> String {
    String(
      localized: "You're the only recipient of \(list), so you can't leave it. You can delete it.", bundle: #bundle)
  }

  /// The words for `list_has_other_recipients`: the list has another recipient now, so it can't be deleted.
  public static func otherRecipients(of list: String) -> String {
    String(
      localized: "\(list) has other recipients now, so it can't be deleted. You can leave it.", bundle: #bundle)
  }

  /// The words for `user_deactivated`, which names the deactivated user that the write was for.
  public static func deactivated(_ name: String) -> String {
    String(
      localized: "Only the admin can reactivate \(name). Until then, you can't change anything for \(name).",
      bundle: #bundle)
  }

  /// The words for a login link that is used or expired. The server gives one answer for both.
  static var linkInvalid: String {
    String(localized: "That link was already used, or it has expired. Ask for a new one.", bundle: #bundle)
  }

  /// The words for a fault of the app: a code that only a fault can cause, or an answer that the app can't read.
  public static var fault: String {
    String(localized: "Something went wrong in Wishbone. Try again.", bundle: #bundle)
  }
}
