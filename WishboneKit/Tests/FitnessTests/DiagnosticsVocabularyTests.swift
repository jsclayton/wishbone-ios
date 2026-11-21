import Testing
import WishboneAPI

/// Every error type of the app picks its side: captured, a breadcrumb, or never. So an error type of the app's code
/// conforms to `Diagnosed`, which names the side where the type is defined, and never to `Error` alone. See
/// "Diagnostics" in `docs/architecture.md`.
enum ErrorSides {
  /// A declaration whose list of types it conforms to names an error protocol.
  static let pattern = #"\b(?:enum|struct|class|actor|extension)\s+[\w.]+(?:<[^>{]*>)?\s*:([^{]*)\{"#

  /// The error protocols that a type of the app's must not conform to on their own.
  static let errorProtocols: Set<String> = ["Error", "LocalizedError", "CustomNSError"]

  static func findings(in files: [SourceFile]) -> [Finding] {
    files.flatMap { file in
      file.matches(of: pattern).compactMap { range -> Finding? in
        let declaration = file.code[range]
        guard let colon = declaration.firstIndex(of: ":") else { return nil }
        let names = declaration[declaration.index(after: colon)...].split { !$0.isLetter && !$0.isNumber && $0 != "_" }
          .map(String.init)
        guard names.contains(where: errorProtocols.contains), !names.contains("Diagnosed") else { return nil }
        return file.finding(at: range.lowerBound, "an error type that names no side for diagnostics")
      }
    }
  }
}

@Suite("The diagnostics vocabulary", .timeLimit(.minutes(1)))
struct DiagnosticsVocabularyTests {
  @Test("Every route that the client calls has its path template on the allow list, and the list has no other")
  func pathTemplates() {
    let templates = Set(Route.allCases.map(\.template))
    #expect(templates.subtracting(Breadcrumb.pathTemplates).isEmpty, "Not on the allow list.")
    #expect(Breadcrumb.pathTemplates.subtracting(templates).isEmpty, "On the allow list, and no route's.")
  }

  @Test("Every error type of the app's code names its side for diagnostics")
  func errorSides() throws {
    // The test support is for the tests only, and ships in no target.
    let files = try Repo.swiftFiles(under: Repo.shipped).filter {
      !$0.path.hasPrefix(Repo.module("TestSupport") + "/")
    }
    let findings = ErrorSides.findings(in: files)
    #expect(findings.isEmpty, "\(findings.report)")
  }

  @Test(
    "The scan catches each error type that names no side",
    arguments: [
      "struct Lost: Error {}",
      "public enum Broken: Error, Sendable, Equatable {\n  case one\n}",
      "final class Failure: NSObject, LocalizedError {}",
      "extension Refused: CustomNSError {}",
      "struct Held<Value>: Sendable, Error where Value: Sendable {}",
    ]
  )
  func scanCatches(source: String) {
    #expect(ErrorSides.findings(in: [SourceFile(path: "Planted.swift", source: source)]).count == 1)
  }

  @Test("The scan allows an error type that names its side, and a type that is not an error")
  func scanAllows() {
    let source = """
      public struct TimedOut: Diagnosed, Sendable {}
      enum Route: String, CaseIterable {}
      // struct Lost: Error {}
      let text = "struct Lost: Error {}"
      func fail() throws(APIError) {}
      """
    #expect(ErrorSides.findings(in: [SourceFile(path: "Planted.swift", source: source)]).isEmpty)
  }
}
