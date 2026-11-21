import Foundation

/// The install marker: a file in the app group's shared container that says this install has signed in. See "A
/// fresh install starts signed out" in `docs/spec.md`.
///
/// iOS keeps the session keychain's item when the app is deleted, and deletes the container. So a session with no
/// marker is left over from an earlier install.
///
/// The marker holds nothing about the family: it is an empty file.
public protocol InstallMarker: Sendable {
  /// Whether this install has placed the marker.
  var isPresent: Bool { get }

  /// Places the marker: writes its file. Placing it again changes nothing.
  func place() throws
}

/// The install marker as a file in a folder: the app group's shared container.
public struct FileInstallMarker: InstallMarker {
  /// The name of the marker's file in the container.
  public static let fileName = "install-marker"

  /// The marker's file.
  public let file: URL

  /// The marker in the folder.
  public init(container: URL) {
    file = container.appending(path: Self.fileName, directoryHint: .notDirectory)
  }

  /// The marker in the shared container of the app group. Nil when the target has no such group in its
  /// entitlements.
  public init?(appGroup: String) {
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
      return nil
    }
    self.init(container: container)
  }

  public var isPresent: Bool {
    FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
  }

  public func place() throws {
    guard !isPresent else { return }
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    // The file uses iOS's default protection, as every file of the app does. See "Data at rest" in `docs/spec.md`.
    try Data().write(to: file)
  }
}
