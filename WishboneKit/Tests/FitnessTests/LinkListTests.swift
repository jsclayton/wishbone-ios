import Foundation
import Testing

/// What each target that ships links from the package. See "Modules" in `docs/architecture.md`.
private let linkLists = [
  "Wishbone": ["WishboneAPI", "WishboneDiagnostics", "WishboneSession", "WishboneUI"],
  "ShareExtension": ["WishboneAPI", "WishboneSession", "WishboneUI"],
  // The widget never links `WishboneSession` or GRDB, and `WishboneUI` imports `WishboneSession`.
  "WidgetExtension": ["WishboneAPI"],
]

/// What each test bundle of the project links from the package.
private let testLinkLists = [
  // The hosted tests run inside the app, and reach the app's modules through it. A second copy of a module in
  // the bundle would give the process two of each of its classes.
  "HostedTests": [String](),
  // The journeys run beside the app, and start the test server.
  "JourneyTests": ["TestSupport", "WishboneAPI"],
]

/// What the files of each test bundle may import: its link list, and for the hosted tests the app's modules.
private let testImportLists = [
  "HostedTests": ["WishboneAPI", "WishboneDiagnostics", "WishboneSession", "WishboneUI"],
  "JourneyTests": ["TestSupport", "WishboneAPI"],
]

@Suite("Each target's link list", .timeLimit(.minutes(1)))
struct LinkListTests {
  let project: XcodeProject

  init() throws {
    project = try XcodeProject(at: Repo.url("Wishbone.xcodeproj/project.pbxproj"))
  }

  @Test("The project has the app, the share extension, the widget extension, and the two test bundles")
  func targets() {
    #expect(Set(project.targets) == Set(linkLists.keys).union(testLinkLists.keys))
    #expect(Set(Repo.targets) == Set(linkLists.keys))
  }

  @Test("A test bundle links only the modules on its list", arguments: testLinkLists.keys.sorted())
  func testLinkList(target: String) throws {
    #expect(try project.linkedPackageProducts(of: target) == testLinkLists[target])
    #expect(try project.packageProductDependencies(of: target) == testLinkLists[target])
  }

  @Test("A test bundle imports only the modules on its list", arguments: testImportLists.keys.sorted())
  func testImports(target: String) throws {
    let list = testImportLists[target] ?? []
    let findings = Imports.findings(in: try Repo.swiftFiles(under: [target])) { module in
      isOurs(module) && !list.contains(module)
    }
    #expect(findings.isEmpty, "\(findings.report)")
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
