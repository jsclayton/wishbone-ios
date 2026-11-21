import Testing

@Suite("One file imports Sentry, and one file imports StoreKit", .timeLimit(.minutes(1)))
struct SingleImportTests {
  @Test("At most one file imports Sentry, in WishboneDiagnostics")
  func sentry() throws {
    let findings = Imports.findings(in: try Repo.swiftFiles(under: Repo.shipped)) { $0.hasPrefix("Sentry") }
    #expect(findings.count <= 1, "\(findings.report)")
    #expect(findings.allSatisfy { $0.path.hasPrefix(Repo.module("WishboneDiagnostics") + "/") }, "\(findings.report)")
  }

  @Test("At most one file imports StoreKit, in the app target")
  func storeKit() throws {
    let findings = Imports.findings(in: try Repo.swiftFiles(under: Repo.shipped)) { $0 == "StoreKit" }
    #expect(findings.count <= 1, "\(findings.report)")
    #expect(findings.allSatisfy { $0.path.hasPrefix("Wishbone/") }, "\(findings.report)")
  }
}
