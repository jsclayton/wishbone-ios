import Foundation
import Testing

/// The Acknowledgements screen shows the full license text of each package that the app ships. See "Source code and
/// Acknowledgements" in `docs/spec.md`.
@Suite("Acknowledgements", .timeLimit(.minutes(1)))
struct AcknowledgementsTests {
  private struct Resolved: Decodable {
    struct Pin: Decodable {
      let location: String
    }

    let pins: [Pin]
  }

  private struct Entry: Decodable {
    let name: String
    let license: String
  }

  @Test("Each package in Package.resolved that the app ships has its license text in the build's output")
  func everyPinHasItsLicense() throws {
    let resolved = try JSONDecoder().decode(
      Resolved.self,
      from: Data(contentsOf: Repo.url("Wishbone.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")))
    let entries = try JSONDecoder().decode(
      [Entry].self, from: Data(contentsOf: Repo.url("WishboneKit/Sources/WishboneUI/Resources/Acknowledgements.json")))

    // The name of a package, as the build step gives it: `GRDB.swift` for `https://github.com/groue/GRDB.swift.git`.
    let pinned = Set(
      resolved.pins.map { pin in
        var name = URL(string: pin.location)?.lastPathComponent ?? pin.location
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name
      })
    #expect(!pinned.isEmpty)
    #expect(Set(entries.map(\.name)) == pinned)
    #expect(entries.count == pinned.count, "A package is in the file twice.")
    for entry in entries {
      #expect(entry.license.contains("Copyright"), "\(entry.name) has no full license text.")
      #expect(entry.license.count > 500, "\(entry.name) has no full license text.")
    }
  }

  @Test("The screen's MPL-2.0 notice has the words of the README's license block")
  func noticeIsTheReadmes() throws {
    let readme = try String(contentsOf: Repo.url("README.md"), encoding: .utf8)
    let notice = try String(
      contentsOf: Repo.url("WishboneKit/Sources/WishboneUI/Resources/Notice.txt"), encoding: .utf8)

    // The block is the first `text` block under "## License".
    let license = try #require(readme.range(of: "\n## License\n"), "The README has no License section.")
    let rest = readme[license.upperBound...]
    let open = try #require(rest.range(of: "```text\n"), "The License section has no text block.")
    let close = try #require(rest[open.upperBound...].range(of: "\n```"), "The text block doesn't end.")
    let block = String(rest[open.upperBound..<close.lowerBound])

    #expect(!block.isEmpty)
    #expect(Self.paragraphs(notice) == Self.paragraphs(block))
  }

  /// The paragraphs of a text, each with its lines joined by one space, so that the README's wrapped lines and the
  /// resource's one line for each paragraph compare equal. A change of any word still differs.
  private static func paragraphs(_ text: String) -> [String] {
    text.components(separatedBy: "\n\n").map { paragraph in
      paragraph.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }.filter { !$0.isEmpty }
  }
}
