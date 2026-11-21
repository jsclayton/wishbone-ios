import Foundation

/// The checkout that the tests run in.
enum Repo {
  /// The repo's root folder. This file is at `WishboneKit/Tests/FitnessTests/Support/Repo.swift`.
  static let root: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 {
      url.deleteLastPathComponent()
    }
    return url
  }()

  /// The folders of the three thin targets. Each has the name of its target.
  static let targets = ["Wishbone", "ShareExtension", "WidgetExtension"]

  /// The folder that holds one folder for each package module.
  static let modules = "WishboneKit/Sources"

  /// Everything that ships: the three targets and the package modules.
  static let shipped = targets + [modules]

  /// The folder of one package module.
  static func module(_ name: String) -> String {
    "\(modules)/\(name)"
  }

  static func url(_ path: String) -> URL {
    root.appending(path: path)
  }

  /// Every Swift file under the folders, in order.
  static func swiftFiles(under folders: [String]) throws -> [SourceFile] {
    try files(under: folders, withExtension: "swift").map { path in
      SourceFile(path: path, source: try String(contentsOf: url(path), encoding: .utf8))
    }
  }

  /// Every file with the extension under the folders, as paths from the repo's root, in order.
  ///
  /// A folder that is missing is an error. A scan of nothing would pass, and hold nothing.
  static func files(under folders: [String], withExtension pathExtension: String) throws -> [String] {
    var paths: [String] = []
    for folder in folders {
      let base = url(folder)
      guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
        throw MissingFolder(path: folder)
      }
      var found = false
      for case let file as URL in walk {
        found = true
        if file.pathExtension == pathExtension {
          paths.append(String(file.standardizedFileURL.path().dropFirst(root.standardizedFileURL.path().count)))
        }
      }
      guard found else { throw MissingFolder(path: folder) }
    }
    return paths.sorted()
  }

  struct MissingFolder: Error {
    let path: String
  }
}
