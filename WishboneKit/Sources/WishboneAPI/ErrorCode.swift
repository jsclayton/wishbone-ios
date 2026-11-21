/// An error code of the API: the `code` of a problem. The app acts on the code, and shows its own words for it.
///
/// The enum is open: a code that the app doesn't know is `unknown`, and the app shows the server's `detail` for
/// it. See "Words for error codes" in `docs/screens/README.md`.
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
  ]

  /// The code for the server's text, such as `login_link_invalid`.
  public init(_ text: String) {
    self = Self.known[text] ?? .unknown(text)
  }
}
