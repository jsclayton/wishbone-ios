import Foundation
import Testing

/// The app icon is a layered Icon Composer document in the app target. See `docs/screens/app-icon.md`.
///
/// iOS draws the light and dark appearances from the document's fills, and the tinted and clear appearances from
/// its layers. A flat image in an asset catalog has no layers, so it can't have the last two.
@Suite("The app icon", .timeLimit(.minutes(1)))
struct AppIconTests {
  static let document = "Wishbone/AppIcon.icon"

  let icon: [String: Any]

  init() throws {
    let data = try Data(contentsOf: Repo.url("\(Self.document)/icon.json"))
    icon = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test("The app target uses the icon, in every configuration")
  func appTarget() throws {
    let project = try XcodeProject(at: Repo.url("Wishbone.xcodeproj/project.pbxproj"))
    #expect(
      try project.buildSetting("ASSETCATALOG_COMPILER_APPICON_NAME", of: "Wishbone") == [
        "Debug": "AppIcon", "Release": "AppIcon",
      ])
  }

  @Test("No asset catalog holds a flat app icon")
  func noFlatIcon() throws {
    let flat = try Repo.targets.flatMap { target in
      try FileManager.default.contentsOfDirectory(atPath: Repo.url("\(target)/Assets.xcassets").path())
        .filter { $0.hasSuffix(".appiconset") }
    }
    #expect(flat.isEmpty)
  }

  @Test("The background has a light fill and a dark fill")
  func lightAndDark() throws {
    let fills = try #require(icon["fill-specializations"] as? [[String: Any]])
    let appearances = fills.filter { $0["value"] != nil }.map { $0["appearance"] as? String ?? "light" }
    #expect(appearances.sorted() == ["dark", "light"])
  }

  @Test("The icon has layers, for the tinted and clear appearances, and each layer's image is in the document")
  func layers() throws {
    let groups = try #require(icon["groups"] as? [[String: Any]])
    let layers = groups.flatMap { $0["layers"] as? [[String: Any]] ?? [] }
    #expect(!layers.isEmpty)
    for layer in layers {
      let image = try #require(layer["image-name"] as? String)
      #expect(FileManager.default.fileExists(atPath: Repo.url("\(Self.document)/Assets/\(image)").path()), "\(image)")
    }
  }

  @Test("The icon is for iPhone and iPad")
  func platforms() throws {
    let platforms = try #require(icon["supported-platforms"] as? [String: Any])
    #expect(platforms["squares"] as? String == "shared")
  }
}
