import Foundation
import Testing
import WishboneAPI

/// The app's privacy manifest. See "Diagnostics" in `docs/architecture.md`, and `PRIVACY.md`.
///
/// What diagnostics send is crash data, app hangs and terminations (performance data), and the app's own faults
/// by code, with their breadcrumbs and the versions (other diagnostic data). None of it is linked to the person, none
/// of it tracks them, and it is only to fix the app. The manifest declares exactly what the event vocabulary can
/// send: `DiagnosticsReport` in `WishboneAPI`.
@Suite("The app's privacy manifest", .timeLimit(.minutes(1)))
struct PrivacyManifestTests {
  @Test(
    "The manifest declares what the diagnostics vocabulary can send, not linked, with no tracking, for the app only")
  func collectedData() throws {
    let data = try Data(contentsOf: Repo.url("Wishbone/PrivacyInfo.xcprivacy"))
    let manifest = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

    #expect(manifest["NSPrivacyTracking"] as? Bool == false)
    #expect((manifest["NSPrivacyTrackingDomains"] as? [String])?.isEmpty == true)

    let collected = try #require(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
    let types = collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String }
    #expect(Set(types) == Set(DiagnosticsReport.allCases.map(\.dataType.rawValue)))
    // Each kind of the app's own events and breadcrumbs is in what the vocabulary can send.
    #expect(Fault.Kind.allCases.allSatisfy { DiagnosticsReport.allCases.contains(.fault($0)) })
    #expect(Breadcrumb.Kind.allCases.allSatisfy { DiagnosticsReport.allCases.contains(.breadcrumb($0)) })
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
