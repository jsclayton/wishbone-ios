import Foundation
import Testing

/// The app's privacy manifest. See "Diagnostics" in `docs/architecture.md`, and `PRIVACY.md`.
///
/// What diagnostics send is crash data, app hangs (performance data), and the app's own faults by code (other
/// diagnostic data). None of it is linked to the person, none of it tracks them, and it is only to fix the app.
/// The event vocabulary joins this test when it is built.
@Suite("The app's privacy manifest", .timeLimit(.minutes(1)))
struct PrivacyManifestTests {
  @Test("The manifest declares what diagnostics collect, not linked, with no tracking, for the app only")
  func collectedData() throws {
    let data = try Data(contentsOf: Repo.url("Wishbone/PrivacyInfo.xcprivacy"))
    let manifest = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

    #expect(manifest["NSPrivacyTracking"] as? Bool == false)
    #expect((manifest["NSPrivacyTrackingDomains"] as? [String])?.isEmpty == true)

    let collected = try #require(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
    let types = collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String }
    #expect(
      Set(types) == [
        "NSPrivacyCollectedDataTypeCrashData",
        "NSPrivacyCollectedDataTypePerformanceData",
        "NSPrivacyCollectedDataTypeOtherDiagnosticData",
      ])
    #expect(types.count == collected.count)
    for type in collected {
      #expect(type["NSPrivacyCollectedDataTypeLinked"] as? Bool == false)
      #expect(type["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
      #expect(
        type["NSPrivacyCollectedDataTypePurposes"] as? [String] == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
      )
    }
  }
}
