/// Why a request to the instance gave no result. Every request ends in a result or in one of these.
///
/// Diagnostics, for each case (see ``diagnosticSide``):
/// - `unreachable`, `cancelled`, `unauthorized`, and `appTooOld`: never. A 5xx is unreachable: it is the operator's
///   server, not the app's fault.
/// - `refused`: captured for a 400 or a 422 of a write that the app sent, as the route and the code, and
///   for a code that is not in `ErrorCode`'s list, as the code only. Otherwise never: a 404 or a 410 for something
///   deleted elsewhere, a 403, a 429, a blocked store (`store_blocked`), and a store's image that the server
///   couldn't download (`image_fetch_failed`).
/// - `undecodable`: captured, as the path template and the key path, never a value. Except for `GET /health`: an
///   address that is not a Wishbone answers it so, and the sign-in says "No Wishbone found".
///
/// The client reports each one as its side asks, where the request ends.
public enum APIError: Diagnosed, Sendable, Equatable {
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
    /// The route that was refused.
    public let route: Route
    public let status: Int
    public let code: ErrorCode
    public let detail: String

    /// The fields of the request's body that the problem's `errors` names, such as `name` or `birthday`, each once,
    /// in the server's order. A 422 `invalid_input` marks them on the form. Empty when the problem names none.
    public let fields: [String]

    public init(route: Route, status: Int, code: ErrorCode, detail: String, fields: [String] = []) {
      self.route = route
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

extension APIError {
  public var diagnosticSide: DiagnosticSide {
    switch self {
    case .unreachable, .cancelled, .unauthorized, .appTooOld: .never
    case .refused(let refusal): refusal.diagnosticSide
    case .undecodable(let answer) where answer.route == .health: .never
    case .undecodable(let answer): .captured(.undecodable(answer.route, keyPath: answer.keyPath))
    }
  }
}

extension APIError.Refusal {
  /// A 400 or a 422 of a write is the app's fault: it sent what the server can't take. So is a code that the app
  /// doesn't know. Any other refusal is the server's answer to the person, and no fault. Nor are a blocked store
  /// (`store_blocked`), which is the operator's setting, and a store's image that the server couldn't download
  /// (`image_fetch_failed`), which is the store's server, though each is a 422 of a write.
  public var diagnosticSide: DiagnosticSide {
    if code == .storeBlocked || code == .imageFetchFailed { return .never }
    if route.isWrite, status == 400 || status == 422 { return .captured(.refused(route, code: code)) }
    if case .unknown(let text) = code { return .captured(.unknown(text)) }
    return .never
  }
}
