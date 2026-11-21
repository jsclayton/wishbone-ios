import Foundation
import WishboneAPI

/// The scrubber's rules for text: the second net under the closed vocabulary. See "What may be sent" in
/// `docs/spec.md`.
///
/// `SentryReporter` holds each event and breadcrumb to the vocabulary first, and drops the SDK's free text. Then it
/// passes every string that is left through ``text(_:)``, which strips tokens, login links, hosts, and anything
/// shaped like an address. Nothing here imports Sentry.
nonisolated enum Scrubber {
  /// The text with every token, login link, host, and address replaced by a word that names what it was.
  static func text(_ text: String) -> String {
    var text = text
    for rule in rules {
      text = rule.apply(to: text)
    }
    return text
  }

  /// One rule: a pattern, what replaces each match, and which matches it keeps.
  private struct Rule: Sendable {
    let pattern: String
    let replacement: String
    var keeps: @Sendable (String) -> Bool = { _ in false }

    func apply(to text: String) -> String {
      // A pattern of this file always compiles.
      guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
      let whole = NSRange(text.startIndex..., in: text)
      var result = text
      for match in expression.matches(in: text, range: whole).reversed() {
        guard let range = Range(match.range, in: result) else { continue }
        if keeps(String(result[range])) { continue }
        result.replaceSubrange(range, with: replacement)
      }
      return result
    }
  }

  /// The rules, in order: what holds the most first, so a login link goes as a link and not as a host.
  private static let rules: [Rule] = [
    // A URL with any scheme: a login link, an instance address, a store link.
    Rule(pattern: #"[A-Za-z][A-Za-z0-9+.\-]*://[^\s"'<>]*"#, replacement: "[url]"),
    // The part of a login link with its token, without the instance before it.
    Rule(pattern: #"/login/[A-Za-z0-9_\-]+"#, replacement: "/login/[token]"),
    // A token in a header.
    Rule(pattern: #"(?i)\bbearer\s+[^\s"']+"#, replacement: "Bearer [token]"),
    // An email address.
    Rule(pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, replacement: "[address]"),
    // An IPv6 address: groups of hex with colons, with a letter of hex or `::`, so a time of day is not one.
    Rule(
      pattern: #"(?<![\w:])(?=[0-9A-Fa-f:]*(?:::|[A-Fa-f]))(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![\w:])"#,
      replacement: "[address]"),
    // An IPv4 address.
    Rule(pattern: #"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])"#, replacement: "[address]"),
    // A token: the server's are 43 characters of base64url. A UUID, such as the diagnostics ID, and a run of hex,
    // such as an event's ID, are not tokens. A mangled Swift symbol starts with `$`, so it is not one either.
    Rule(
      pattern: #"(?<![$\w\-])[A-Za-z0-9_\-]{32,}(?![\w\-])"#, replacement: "[token]",
      keeps: { isUUID($0) || $0.allSatisfy(\.isHexDigit) }),
    // A host: labels with dots, the last one of letters. A file's name, such as `libswiftCore.dylib`, is not one.
    Rule(
      pattern:
        #"(?<![\w.\-@/])(?:[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z][A-Za-z0-9\-]{0,61}(?::\d{1,5})?(?![\w\-])"#,
      replacement: "[host]",
      keeps: { match in
        let host = match.split(separator: ":").first.map(String.init) ?? match
        let last = host.split(separator: ".").last.map { $0.lowercased() } ?? ""
        return fileExtensions.contains(last)
      }),
    Rule(pattern: #"(?i)\blocalhost(?::\d{1,5})?\b"#, replacement: "[host]"),
  ]

  /// The extensions of the files that a stack names. A name that ends in one is a file, not a host.
  private static let fileExtensions: Set<String> = [
    "a", "app", "appex", "bundle", "c", "cc", "cpp", "dylib", "framework", "h", "hpp", "json", "m", "mm", "o",
    "plist", "so", "sqlite", "swift", "tbd", "xpc",
  ]

  /// Whether the text is shaped like a UUID.
  static func isUUID(_ text: String) -> Bool {
    UUID(uuidString: text) != nil
  }

  // MARK: - Paths

  /// The part of a file's path inside the app's bundle: `Frameworks/Sentry.framework/Sentry` for
  /// `/private/var/containers/Bundle/Application/<UUID>/Wishbone.app/Frameworks/Sentry.framework/Sentry`. A path in
  /// any other container keeps only its last part, and none when that part is the container's UUID. A system path,
  /// which is the same on every device, stays.
  static func pathInsideBundle(_ path: String) -> String {
    if let bundle = path.range(of: ".app/") {
      return String(path[bundle.upperBound...])
    }
    if path.range(of: "/containers/", options: .caseInsensitive) != nil {
      let last = (path as NSString).lastPathComponent
      return isUUID(last) ? "" : last
    }
    return path
  }

  // MARK: - The vocabulary

  /// The fields of a breadcrumb that the app made, held to the vocabulary: its kind's fields, each with one of its
  /// values. Nil for a breadcrumb that is not the app's, or that has anything else.
  static func breadcrumbFields(category: String, data: [String: Any]) -> [String: String]? {
    guard let kind = Breadcrumb.Kind(rawValue: category), Set(data.keys) == kind.fields else { return nil }
    var fields: [String: String] = [:]
    for (key, value) in data {
      guard let value = value as? String, kind.values[key]?.contains(value) == true else { return nil }
      fields[key] = value
    }
    return fields
  }

  /// The fields of a fault's context, held to its kind: only the kind's fields, with numbers as numbers and words
  /// passed through ``text(_:)``. Nil for a context that is not a fault's.
  static func faultFields(_ context: [String: Any], kind name: String?) -> [String: Any]? {
    guard let name, let kind = Fault.Kind(rawValue: name) else { return nil }
    var fields: [String: Any] = [:]
    for key in kind.fields {
      switch context[key] {
      case let value as String: fields[key] = isWord(value) ? text(value) : "(unreadable)"
      case let value as NSNumber: fields[key] = value
      default: break
      }
    }
    return fields
  }

  /// Whether the text is shaped like a word of the vocabulary: a code, a method, a path template, or a key path.
  static func isWord(_ text: String) -> Bool {
    text.count <= 128 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_./{}[]()-".contains($0)) }
  }

  /// The tag of the Wishbone version, held to the shape of a version. Anything else goes as `unreadable`.
  static func versionTag(_ tag: String?) -> String {
    guard let tag else { return "unknown" }
    let isShaped =
      (1...32).contains(tag.count) && tag.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-".contains($0)) }
    return isShaped ? text(tag) : "unreadable"
  }

  /// A word that names a kind of crash or exception, such as `EXC_BAD_ACCESS` or `App Hanging`. Anything else, such
  /// as the reason of an exception, is not sent.
  static func name(_ text: String?) -> String? {
    guard let text, (1...64).contains(text.count),
      text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_. ".contains($0)) })
    else { return nil }
    return Self.text(text)
  }

  /// The instance's Wishbone version as the tag gives it: the version that `GET /health` gave, or `unknown`.
  static func versionTag(_ version: ServerVersion?) -> String {
    guard let version else { return "unknown" }
    return versionTag(version.text)
  }
}
