import Foundation
import Testing
import WishboneAPI

/// The install marker's file, with the app's entitlements. See "A fresh install starts signed out" and "Data at
/// rest" in `docs/spec.md`.
@Suite("The install marker", .timeLimit(.minutes(1)))
struct InstallMarkerTests {
  @Test("The marker's file is in the app group's shared container, and holds nothing")
  func file() throws {
    let bundleID = try #require(Bundle.main.bundleIdentifier)
    let appGroup = try #require(Bundle.main.object(forInfoDictionaryKey: "WishboneAppGroup") as? String)
    // The group is the one that the app's entitlements name, for the bundle prefix, which is the app's own bundle ID.
    #expect(appGroup == "group.\(bundleID)")
    let container = try #require(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup))

    let marker = try #require(FileInstallMarker(appGroup: appGroup))
    #expect(marker.file.deletingLastPathComponent().standardizedFileURL == container.standardizedFileURL)
    #expect(marker.file.lastPathComponent == FileInstallMarker.fileName)

    try marker.place()
    #expect(marker.isPresent)
    #expect(FileManager.default.fileExists(atPath: container.appending(path: FileInstallMarker.fileName).path()))
    // The marker holds nothing about the family.
    #expect(try Data(contentsOf: marker.file).isEmpty)
  }
}
