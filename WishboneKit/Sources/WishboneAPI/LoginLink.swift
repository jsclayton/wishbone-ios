import Foundation

/// A login link: an `http` or `https` URL with `/login/` and a token after it.
///
/// See "Scan or paste signs in at once" in `docs/spec.md`. The link is a secret until it is used, so its
/// description leaves the token out.
public struct LoginLink: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
  /// The instance that the link signs in to: all the text before `/login/`.
  public let instance: InstanceAddress

  /// The token after `/login/`.
  let token: String

  /// Reads a login link from text that a person pasted or scanned. Nil for anything else.
  public init?(_ text: String) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // An instance address can have a path of its own, so the mark is the last `/login/`.
    guard let mark = text.range(of: "/login/", options: .backwards),
      let instance = InstanceAddress(String(text[..<mark.lowerBound]))
    else { return nil }
    let token = text[mark.upperBound...]
    guard !token.isEmpty, !token.contains(where: { "/?#".contains($0) || $0.isWhitespace }) else { return nil }
    self.instance = instance
    self.token = String(token)
  }

  public var description: String {
    "a login link for \(instance)"
  }

  public var debugDescription: String {
    description
  }
}
