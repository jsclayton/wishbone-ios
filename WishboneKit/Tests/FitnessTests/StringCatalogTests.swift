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
  /// and not waiting for review.
  var keysWithoutEnglish: [String] {
    strings.filter { key, entry in
      guard let english = entry.localizations?[sourceLanguage] else {
        return entry.extractionState == "manual" || key.allSatisfy(\.isWhitespace)
      }
      return english.units.isEmpty || english.units.contains { $0.state != "translated" || $0.value.isEmpty }
    }.keys.sorted()
  }
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

  @Test("The package has one String Catalog, in WishboneUI, in English")
  func oneCatalog() throws {
    let inPackage = catalogs.keys.filter { $0.hasPrefix(Repo.modules + "/") }
    #expect(inPackage == [Repo.module("WishboneUI") + "/Resources/Localizable.xcstrings"])
    #expect(catalogs.values.allSatisfy { $0.sourceLanguage == "en" })
    // The signed-out screen has strings, so an empty catalog is one that the build never filled.
    #expect(catalogs.values.contains { !$0.strings.isEmpty })
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
      catalog.keysWithoutEnglish == ["%lld lists", "empty.english", "new.english", "only.french", "signedOut.title"])
  }
}
