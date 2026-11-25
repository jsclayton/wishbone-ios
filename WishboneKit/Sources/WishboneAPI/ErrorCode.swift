/// An error code of the API: the `code` of a problem. The app acts on the code, and shows its own words for it.
///
/// The enum is open: a code that the app doesn't know is `unknown`, and the app shows the server's `detail` for
/// it. See "Words for error codes" in `docs/screens/README.md`. Each ticket adds the codes that its routes answer
/// with.
public enum ErrorCode: Sendable, Hashable {
  case unauthorized
  case loginLinkInvalid
  case rateLimited
  case invalidInput
  case notFound
  case apiVersionRemoved
  case unknownFilter
  case unknownSort
  case cursorMismatch
  case forbidden
  case fieldNotWritable
  case referenceNotFound
  case userDeactivated
  case birthdayRequired
  case adminHasNoParents
  case parentLoop
  case requestTooLarge
  case imageTooLarge
  case imageInvalid
  case imageAttached
  case resourceChanged
  case lastRecipient
  case primaryList
  case alreadyClaimed
  case alreadyInvited
  case alreadyRecipient
  case alreadyInGroup
  case alreadyAttached
  case alreadyBlocked
  case itemFullyClaimed
  case recipientCannotClaim
  case quantityRaiseNotAllowed
  case occasionNotAllowed
  case imageFetchFailed
  case storeBlocked
  case tooManyImages
  case tooManyStoreLinks
  case giftGiven
  case unknown(String)

  private static let known: [String: ErrorCode] = [
    "unauthorized": .unauthorized,
    "login_link_invalid": .loginLinkInvalid,
    "rate_limited": .rateLimited,
    "invalid_input": .invalidInput,
    "not_found": .notFound,
    "api_version_removed": .apiVersionRemoved,
    "unknown_filter": .unknownFilter,
    "unknown_sort": .unknownSort,
    "cursor_mismatch": .cursorMismatch,
    "forbidden": .forbidden,
    "field_not_writable": .fieldNotWritable,
    "reference_not_found": .referenceNotFound,
    "user_deactivated": .userDeactivated,
    "birthday_required": .birthdayRequired,
    "admin_has_no_parents": .adminHasNoParents,
    "parent_loop": .parentLoop,
    "request_too_large": .requestTooLarge,
    "image_too_large": .imageTooLarge,
    "image_invalid": .imageInvalid,
    "image_attached": .imageAttached,
    "resource_changed": .resourceChanged,
    "last_recipient": .lastRecipient,
    "primary_list": .primaryList,
    "already_claimed": .alreadyClaimed,
    "already_invited": .alreadyInvited,
    "already_recipient": .alreadyRecipient,
    "already_in_group": .alreadyInGroup,
    "already_attached": .alreadyAttached,
    "already_blocked": .alreadyBlocked,
    "item_fully_claimed": .itemFullyClaimed,
    "recipient_cannot_claim": .recipientCannotClaim,
    "quantity_raise_not_allowed": .quantityRaiseNotAllowed,
    "occasion_not_allowed": .occasionNotAllowed,
    "image_fetch_failed": .imageFetchFailed,
    "store_blocked": .storeBlocked,
    "too_many_images": .tooManyImages,
    "too_many_store_links": .tooManyStoreLinks,
    "gift_given": .giftGiven,
  ]

  /// The server's text for the code, such as `login_link_invalid`.
  public var text: String {
    if case .unknown(let text) = self { return text }
    return Self.known.first { $0.value == self }?.key ?? ""
  }

  /// The code for the server's text, such as `login_link_invalid`.
  public init(_ text: String) {
    self = Self.known[text] ?? .unknown(text)
  }

  /// Whether the code counts as success: the server already has what the write asked for. The app shows nothing
  /// for it.
  public var isSuccess: Bool {
    switch self {
    case .alreadyClaimed, .alreadyInvited, .alreadyRecipient, .alreadyInGroup, .alreadyAttached, .alreadyBlocked: true
    default: false
    }
  }
}
