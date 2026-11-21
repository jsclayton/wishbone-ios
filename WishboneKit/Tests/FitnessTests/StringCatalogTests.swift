import Foundation
import Testing

/// What the fitness tests read from a String Catalog (an `.xcstrings` file).
struct StringCatalog: Decodable {
  let sourceLanguage: String
  let strings: [String: Entry]

  struct Entry: Decodable {
    /// `manual` for a key that a person added, `stale` for a key that the code no longer uses, and nothing for a
    /// key that the build found in the code.
    let extractionState: String?
    let localizations: [String: Localization]?
  }

  struct Localization: Decodable {
    let stringUnit: StringUnit?
    let variations: [String: [String: Localization]]?

    /// Every piece of text in the localization: the one string, or each plural or device variation.
    var units: [StringUnit] {
      (stringUnit.map { [$0] } ?? []) + (variations ?? [:]).values.flatMap { $0.values.flatMap(\.units) }
    }
  }

  struct StringUnit: Decodable {
    let state: String
    let value: String
  }

  init(_ json: String) throws {
    self = try JSONDecoder().decode(StringCatalog.self, from: Data(json.utf8))
  }

  /// The keys that the code no longer uses.
  var staleKeys: [String] {
    strings.filter { $0.value.extractionState == "stale" }.keys.sorted()
  }

  /// The keys with no English.
  ///
  /// A key that the build found in the code is its own English, so it needs none written out. A key that a person
  /// added by hand has no English until someone writes it. English that is written out must be whole: not empty,
  /// and not waiting for review. The build writes the `defaultValue:` of a string in the state `new`, and that
  /// English is whole too.
  var keysWithoutEnglish: [String] {
    strings.filter { key, entry in
      guard let english = entry.localizations?[sourceLanguage] else {
        return entry.extractionState == "manual" || key.allSatisfy(\.isWhitespace)
      }
      let fromTheBuild = entry.extractionState == "extracted_with_value"
      return english.units.isEmpty
        || english.units.contains { unit in
          unit.value.isEmpty || !(unit.state == "translated" || (unit.state == "new" && fromTheBuild))
        }
    }.keys.sorted()
  }

  /// The String Catalogs that are out of place. The package has one, in `WishboneUI`. A target may hold only
  /// `InfoPlist.xcstrings`, for its permission strings. See "Strings" in `docs/architecture.md`.
  static func outOfPlace(_ paths: [String]) -> [String] {
    paths.filter { path in
      let inTarget = Repo.targets.contains { path.hasPrefix("\($0)/") }
      return inTarget ? !path.hasSuffix("/InfoPlist.xcstrings") : path != packageCatalog
    }.sorted()
  }

  static let packageCatalog = Repo.module("WishboneUI") + "/Resources/Localizable.xcstrings"
}

@Suite("The String Catalog", .timeLimit(.minutes(1)))
struct StringCatalogTests {
  let catalogs: [String: StringCatalog]

  init() throws {
    let paths = try Repo.files(under: Repo.shipped, withExtension: "xcstrings")
    catalogs = try Dictionary(
      uniqueKeysWithValues: paths.map { path in
        (path, try StringCatalog(String(contentsOf: Repo.url(path), encoding: .utf8)))
      }
    )
  }

  @Test("The package has one String Catalog, in WishboneUI, and a target holds only InfoPlist.xcstrings")
  func oneCatalog() throws {
    #expect(catalogs.keys.contains(StringCatalog.packageCatalog))
    #expect(StringCatalog.outOfPlace(Array(catalogs.keys)) == [])
  }

  @Test("The check catches a String Catalog that is out of place")
  func outOfPlace() {
    let paths = [
      StringCatalog.packageCatalog,
      "Wishbone/InfoPlist.xcstrings",
      "Wishbone/Localizable.xcstrings",
      "ShareExtension/Strings/Other.xcstrings",
      "WishboneKit/Sources/WishboneAPI/Resources/Localizable.xcstrings",
      "WishboneKit/Sources/WishboneUI/Resources/Other.xcstrings",
    ]
    #expect(
      StringCatalog.outOfPlace(paths) == [
        "ShareExtension/Strings/Other.xcstrings",
        "Wishbone/Localizable.xcstrings",
        "WishboneKit/Sources/WishboneAPI/Resources/Localizable.xcstrings",
        "WishboneKit/Sources/WishboneUI/Resources/Other.xcstrings",
      ]
    )
  }

  @Test("Every String Catalog is in English, and the package's has strings")
  func english() throws {
    #expect(catalogs.values.allSatisfy { $0.sourceLanguage == "en" })
    // The signed-out screen has strings, so an empty catalog is one that the build never filled.
    let package = try #require(catalogs[StringCatalog.packageCatalog])
    #expect(!package.strings.isEmpty)
  }

  @Test("No String Catalog has a stale entry")
  func noStaleEntry() {
    for (path, catalog) in catalogs {
      #expect(catalog.staleKeys.isEmpty, "\(path)")
    }
  }

  @Test("No String Catalog has a key without English")
  func noKeyWithoutEnglish() {
    for (path, catalog) in catalogs {
      #expect(catalog.keysWithoutEnglish.isEmpty, "\(path)")
    }
  }

  @Test("The checks catch a stale entry and each kind of key without English")
  func checksCatch() throws {
    let catalog = try StringCatalog(
      """
      {
        "sourceLanguage" : "en",
        "strings" : {
          "Scan QR code" : {},
          "Signed in as %@" : {
            "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Signed in as %@" } } }
          },
          "%lld gifts" : {
            "localizations" : { "en" : { "variations" : { "plural" : {
              "one" : { "stringUnit" : { "state" : "translated", "value" : "%lld gift" } },
              "other" : { "stringUnit" : { "state" : "translated", "value" : "%lld gifts" } }
            } } } }
          },
          "reminder.title" : {
            "extractionState" : "extracted_with_value",
            "localizations" : { "en" : { "stringUnit" : { "state" : "new", "value" : "A birthday is soon" } } }
          },
          "reminder.body" : {
            "extractionState" : "extracted_with_value",
            "localizations" : { "en" : { "stringUnit" : { "state" : "new", "value" : "" } } }
          },
          "Old words" : { "extractionState" : "stale" },
          "signedOut.title" : { "extractionState" : "manual" },
          "empty.english" : {
            "extractionState" : "manual",
            "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "" } } }
          },
          "new.english" : {
            "localizations" : { "en" : { "stringUnit" : { "state" : "new", "value" : "Draft" } } }
          },
          "%lld lists" : {
            "localizations" : { "en" : { "variations" : { "plural" : {
              "one" : { "stringUnit" : { "state" : "translated", "value" : "%lld list" } },
              "other" : { "stringUnit" : { "state" : "new", "value" : "" } }
            } } } }
          },
          "only.french" : {
            "extractionState" : "manual",
            "localizations" : { "fr" : { "stringUnit" : { "state" : "translated", "value" : "Bonjour" } } }
          }
        },
        "version" : "1.0"
      }
      """
    )
    #expect(catalog.staleKeys == ["Old words"])
    #expect(
      catalog.keysWithoutEnglish == [
        "%lld lists", "empty.english", "new.english", "only.french", "reminder.body", "signedOut.title",
      ]
    )
  }
}
