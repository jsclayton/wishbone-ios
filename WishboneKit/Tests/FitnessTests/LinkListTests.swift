import Foundation
import Testing

/// What each target links from the package. See "Modules" in `docs/architecture.md`.
private let linkLists = [
  "Wishbone": ["WishboneAPI", "WishboneDiagnostics", "WishboneSession", "WishboneUI"],
  "ShareExtension": ["WishboneAPI", "WishboneSession", "WishboneUI"],
  "WidgetExtension": ["WishboneAPI", "WishboneUI"],
]

@Suite("Each target's link list", .timeLimit(.minutes(1)))
struct LinkListTests {
  let project: XcodeProject

  init() throws {
    project = try XcodeProject(at: Repo.url("Wishbone.xcodeproj/project.pbxproj"))
  }

  @Test("The project has the app, the share extension, and the widget extension")
  func targets() {
    #expect(Set(project.targets) == Set(linkLists.keys))
    #expect(Set(Repo.targets) == Set(linkLists.keys))
  }

  @Test("A target links only the modules on its list", arguments: linkLists.keys.sorted())
  func linkList(target: String) throws {
    #expect(try project.linkedPackageProducts(of: target) == linkLists[target])
    #expect(try project.packageProductDependencies(of: target) == linkLists[target])
  }

  @Test("Only the app links WishboneDiagnostics")
  func diagnostics() throws {
    let linkers = try project.targets.filter {
      try project.linkedPackageProducts(of: $0).contains("WishboneDiagnostics")
    }
    #expect(linkers == ["Wishbone"])
  }

  @Test("A target imports only the modules on its list", arguments: linkLists.keys.sorted())
  func imports(target: String) throws {
    let list = linkLists[target] ?? []
    let findings = Imports.findings(in: try Repo.swiftFiles(under: [target])) { module in
      isOurs(module) && !list.contains(module)
    }
    #expect(findings.isEmpty, "\(findings.report)")
  }

  /// The libraries are static, so a target carries every module that a module on its list imports. This test
  /// keeps a target from carrying a module that is not on its list.
  @Test("A module on a target's list imports only the modules on that list", arguments: linkLists.keys.sorted())
  func moduleImports(target: String) throws {
    let list = linkLists[target] ?? []
    let findings = Imports.findings(in: try Repo.swiftFiles(under: list.map(Repo.module))) { module in
      isOurs(module) && !list.contains(module)
    }
    #expect(findings.isEmpty, "\(findings.report)")
  }

  /// Whether the module is one of the package's.
  private func isOurs(_ module: String) -> Bool {
    module.hasPrefix("Wishbone") || module == "TestSupport"
  }

  @Test("The scan reads every form of import")
  func scanReadsImports() {
    let file = SourceFile(
      path: "Planted.swift",
      source: """
        import SwiftUI
        @preconcurrency import Sentry
        public import struct WishboneAPI.Item
          @testable import TestSupport
        // import StoreKit
        let text = "import StoreKit"
        """
    )
    #expect(Imports.modules(in: file).map(\.module) == ["SwiftUI", "Sentry", "WishboneAPI", "TestSupport"])
  }
}
