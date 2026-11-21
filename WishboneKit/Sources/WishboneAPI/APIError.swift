/// Why a request to the instance gave no result. Every request ends in a result or in one of these.
///
/// Diagnostics, for each case:
/// - `unreachable`, `cancelled`, `unauthorized`, and `appTooOld`: never.
/// - `refused`: captured only for a 400 or a 422 of a write that the app sent, and for a code that is not in
///   `ErrorCode`'s list. Otherwise never.
/// - `undecodable`: captured, as the path template and the key path, never a value.
///
/// Nothing is captured yet: the app has no diagnostics until `WishboneDiagnostics` holds them.
public enum APIError: Error, Sendable, Equatable {
  /// The instance can't be reached. See "Unreachable never ends the session" in `docs/spec.md`.
  case unreachable(Unreachable)

  /// The task that made the request was cancelled.
  case cancelled

  /// The API's own 401: `application/problem+json` with the code `unauthorized`. The session is over.
  case unauthorized

  /// The API's own 410 with the code `api_version_removed`: this version of the app is too old for the instance.
  case appTooOld

  /// The API's own refusal: a problem with a code.
  case refused(Refusal)

  /// An answer of the API that the client can't decode.
  case undecodable(Undecodable)

  /// The ways that an instance is unreachable. They differ only before sign-in, where an answer from something
  /// else means that the login link points somewhere else, and a certificate gets its own message.
  public enum Unreachable: Sendable, Equatable {
    /// No network, a timeout, a DNS or TLS failure other than the certificate, or a 5xx.
    case noAnswer
    /// The device doesn't trust the instance's certificate: it is self-signed, from a certificate authority that
    /// the device doesn't have, out of date, or not yet valid. There is no way around it.
    case untrustedCertificate
    /// An answer that is not the API's own: from a reverse proxy, an access gateway, a captive portal, or another
    /// site. A redirect is one too, because the token goes only to the instance address.
    case notTheAPI
  }

  /// A problem of the API. The app shows its own words for the code, and the server's `detail` only for a code
  /// that it doesn't know.
  public struct Refusal: Sendable, Equatable {
    public let status: Int
    public let code: ErrorCode
    public let detail: String

    /// The fields of the request's body that the problem's `errors` names, such as `name` or `birthday`, each once,
    /// in the server's order. A 422 `invalid_input` marks them on the form. Empty when the problem names none.
    public let fields: [String]

    public init(status: Int, code: ErrorCode, detail: String, fields: [String] = []) {
      self.status = status
      self.code = code
      self.detail = detail
      self.fields = fields
    }
  }

  /// Where an answer didn't decode: the route, and the key path that failed. It holds no value of the answer.
  public struct Undecodable: Sendable, Equatable {
    public let route: Route
    public let keyPath: String
  }
}
