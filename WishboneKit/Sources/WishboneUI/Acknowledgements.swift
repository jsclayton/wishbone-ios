import Foundation

/// What the Acknowledgements screen shows: the app's own notice, then the packages that the app ships. Both are in
/// the module's resources, so the screen needs no connection. See "Source code and Acknowledgements" in
/// `docs/spec.md`.
///
/// The notices are the licenses' own words, and are not translated.
public enum Acknowledgements {
  /// One package that the app ships: its name, and its license's full text.
  public struct Package: Decodable, Identifiable, Sendable {
    public let name: String
    public let license: String

    public var id: String { name }
  }

  /// The app's own MPL-2.0 notice (see ADR 0009), from `Notice.txt`. It has the words of the README's license block,
  /// with each paragraph on one line so that it wraps to the screen. A fitness test holds the two equal. Empty when
  /// the file is not in the module.
  public static let notice: String = {
    guard let url = #bundle.url(forResource: noticeFile, withExtension: textType),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else { return "" }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }()

  /// The packages, from `Acknowledgements.json`, in the order of the file. `just build` makes the file from the
  /// pinned packages. Empty when the file is not in the module, or doesn't decode: a hosted test fails then.
  public static let packages: [Package] = {
    guard let url = #bundle.url(forResource: packagesFile, withExtension: jsonType),
      let data = try? Data(contentsOf: url)
    else { return [] }
    return (try? JSONDecoder().decode([Package].self, from: data)) ?? []
  }()

  /// The files in the module's resources. They name files, and show no words.
  private static let noticeFile = "Notice"
  private static let textType = "txt"
  private static let packagesFile = "Acknowledgements"
  private static let jsonType = "json"
}
