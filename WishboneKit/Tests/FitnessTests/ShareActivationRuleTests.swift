import Foundation
import Testing

/// The share extension's activation rule: Wishbone is offered for one web link or one text, and never for several
/// things, a file, or an image. App Review refuses a rule of `TRUEPREDICATE`, and App Store Connect refuses
/// `FALSEPREDICATE`. See "The share extension" in `docs/spec.md`.
@Suite("The share extension's activation rule")
struct ShareActivationRuleTests {
  /// The rule, from the extension's `Info.plist`.
  static func rule() throws -> NSPredicate {
    let file = Repo.root.appending(path: "ShareExtension/Info.plist")
    let plist = try #require(
      try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
    let attributes = (plist["NSExtension"] as? [String: Any])?["NSExtensionAttributes"] as? [String: Any]
    let text = try #require(attributes?["NSExtensionActivationRule"] as? String)
    #expect(!text.contains("TRUEPREDICATE") && !text.contains("FALSEPREDICATE"))
    return NSPredicate(format: text)
  }

  /// What a share sheet hands the rule: its items, each with its attachments, each with the types it has.
  static func shared(_ items: [[[String]]]) -> [String: Any] {
    [
      "extensionItems": items.map { attachments in
        ["attachments": attachments.map { types in ["registeredTypeIdentifiers": types] }]
      }
    ]
  }

  @Test("Offered for one web link, as Safari shares a page, and for one text")
  func offered() throws {
    let rule = try Self.rule()
    #expect(rule.evaluate(with: Self.shared([[["public.url"]]])))
    #expect(rule.evaluate(with: Self.shared([[["public.url", "public.plain-text"]]])))
    #expect(rule.evaluate(with: Self.shared([[["public.plain-text"]]])))
    #expect(rule.evaluate(with: Self.shared([[["public.utf8-plain-text"]]])))
  }

  @Test("Not offered for several things, a file, an image, or nothing")
  func notOffered() throws {
    let rule = try Self.rule()
    #expect(!rule.evaluate(with: Self.shared([[["public.url"], ["public.plain-text"]]])))
    #expect(!rule.evaluate(with: Self.shared([[["public.url"]], [["public.plain-text"]]])))
    #expect(!rule.evaluate(with: Self.shared([[["public.file-url", "public.plain-text"]]])))
    #expect(!rule.evaluate(with: Self.shared([[["public.jpeg"]]])))
    #expect(!rule.evaluate(with: Self.shared([[["public.png", "public.file-url"]]])))
    #expect(!rule.evaluate(with: Self.shared([[]])))
    #expect(!rule.evaluate(with: Self.shared([])))
  }
}
