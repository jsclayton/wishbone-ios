import Foundation
import Testing

/// The share extension's activation rule: Wishbone is offered for one web link, one text or one image, and never for
/// several things, a file that is not an image, or an image with a link. App Review refuses a rule of `TRUEPREDICATE`, and App Store Connect refuses
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

  @Test("Offered for one image: a photo, as Photos shares it, a screenshot, and an image file")
  func offeredForOneImage() throws {
    let rule = try Self.rule()
    #expect(rule.evaluate(with: Self.shared([[["public.heic"]]])))
    #expect(rule.evaluate(with: Self.shared([[["public.jpeg"]]])))
    #expect(rule.evaluate(with: Self.shared([[["public.png"]]])))
    #expect(rule.evaluate(with: Self.shared([[["public.heic", "public.jpeg"]]])))
    #expect(rule.evaluate(with: Self.shared([[["public.png", "public.file-url"]]])))
    // An image with a caption is still one image.
    #expect(rule.evaluate(with: Self.shared([[["public.jpeg", "public.plain-text"]]])))
  }

  @Test("Not offered for several things, a file, two images, an image with a link, or nothing")
  func notOffered() throws {
    let rule = try Self.rule()
    #expect(!rule.evaluate(with: Self.shared([[["public.url"], ["public.plain-text"]]])))
    #expect(!rule.evaluate(with: Self.shared([[["public.url"]], [["public.plain-text"]]])))
    // A file that is not an image.
    #expect(!rule.evaluate(with: Self.shared([[["public.file-url", "public.plain-text"]]])))
    #expect(!rule.evaluate(with: Self.shared([[["public.file-url", "com.adobe.pdf"]]])))
    #expect(!rule.evaluate(with: Self.shared([[["com.adobe.pdf"]]])))
    #expect(!rule.evaluate(with: Self.shared([[["public.movie"]]])))
    // Two images, as one item or as two.
    #expect(!rule.evaluate(with: Self.shared([[["public.heic"], ["public.heic"]]])))
    #expect(!rule.evaluate(with: Self.shared([[["public.jpeg"]], [["public.png"]]])))
    // An image with a link, as two attachments or in one.
    #expect(!rule.evaluate(with: Self.shared([[["public.url"], ["public.jpeg"]]])))
    #expect(!rule.evaluate(with: Self.shared([[["public.jpeg", "public.url"]]])))
    #expect(!rule.evaluate(with: Self.shared([[]])))
    #expect(!rule.evaluate(with: Self.shared([])))
  }
}
