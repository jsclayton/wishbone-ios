import Foundation
import Testing
import WishboneUI

/// Settings: its sections in their order, and its About section, in the app's own build. See
/// `docs/screens/settings.md`.
@Suite("Settings", .timeLimit(.minutes(1)))
@MainActor
struct SettingsTests {
  @Test("The sections and their order, for an everyday user, a child and the admin")
  func sections() {
    // Support Wishbone and the other sections join in their places when they are built.
    let order: [SettingsSection] = [.signedIn, .signInAndDevices, .reminders, .shareDiagnostics, .about]
    #expect(SettingsSection.shown(isAdmin: false, hasParents: false) == order, "An everyday user")
    #expect(SettingsSection.shown(isAdmin: false, hasParents: true) == order, "A child")
    // Only the admin gets For the admin, after Share diagnostics.
    #expect(
      SettingsSection.shown(isAdmin: true, hasParents: false)
        == [.signedIn, .signInAndDevices, .reminders, .shareDiagnostics, .forTheAdmin, .about], "The admin")
    // About is at the foot.
    #expect(SettingsSection.allCases.last == .about)
  }

  @Test("The For the admin footer's link opens the build setting's address: the server's docs")
  func operatorDocs() throws {
    // The app's Info.plist takes the address from `WISHBONE_OPERATOR_DOCS_URL` in `Config/Shared.xcconfig`.
    let setting = try #require(Bundle.main.object(forInfoDictionaryKey: "WishboneOperatorDocsURL") as? String)
    let docs = try #require(AppAbout.current.operatorDocs)
    #expect(docs == URL(string: setting))
    #expect(docs.scheme == "https")
    #expect(AppAbout(info: ["WishboneOperatorDocsURL": "file:///etc/hosts"]).operatorDocs == nil)
  }

  @Test("Source code opens the build setting's address")
  func sourceCode() throws {
    // The app's Info.plist takes the address from `WISHBONE_SOURCE_URL` in `Config/Shared.xcconfig`.
    let setting = try #require(Bundle.main.object(forInfoDictionaryKey: "WishboneSourceURL") as? String)
    let sourceCode = try #require(AppAbout.current.sourceCode)
    #expect(sourceCode == URL(string: setting))
    #expect(sourceCode.scheme == "https")

    // The version and build are the app's own.
    let info = try #require(Bundle.main.infoDictionary)
    #expect(AppAbout.current.version == info["CFBundleShortVersionString"] as? String)
    #expect(AppAbout.current.build == info["CFBundleVersion"] as? String)
    #expect(!AppAbout.current.version.isEmpty)

    // A build with no address, or one that is not a web address, has no Source code row.
    #expect(AppAbout(info: [:]).sourceCode == nil)
    #expect(AppAbout(info: [:]).operatorDocs == nil)
    #expect(AppAbout(info: ["WishboneSourceURL": ""]).sourceCode == nil)
    #expect(AppAbout(info: ["WishboneSourceURL": "file:///etc/hosts"]).sourceCode == nil)
    #expect(
      AppAbout(info: ["WishboneSourceURL": "https://example.com/fork"]).sourceCode
        == URL(string: "https://example.com/fork"))
  }
}
