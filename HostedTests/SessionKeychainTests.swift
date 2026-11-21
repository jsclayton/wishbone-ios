import Foundation
import Security
import Testing
import WishboneAPI
import WishboneSession

/// The session keychain's item, in the system's Keychain, with the app's entitlements. See "Where the session
/// lives" in `docs/spec.md`.
///
/// The tests share the one item of the app's access group, so they run one at a time.
@Suite("The session keychain's item", .serialized, .timeLimit(.minutes(1)))
struct SessionKeychainTests {
  @Test("The item is in the shared access group, stays on this device, and is readable after the first unlock")
  func item() throws {
    let bundleID = try #require(Bundle.main.bundleIdentifier)
    let accessGroup = try #require(Bundle.main.object(forInfoDictionaryKey: "WishboneKeychainAccessGroup") as? String)
    // The group is the team's prefix and the bundle prefix, which is the app's own bundle ID.
    #expect(accessGroup.hasSuffix(".\(bundleID)"))
    #expect(accessGroup.count > bundleID.count + 1)

    let keychain = SystemSessionKeychain(accessGroup: accessGroup)
    try keychain.delete()
    #expect(try keychain.read() == nil)

    let instance = try #require(InstanceAddress("http://10.0.0.5:8080/family"))
    let session = Session(instance: instance, token: "a-token-for-the-test", userID: "7")
    try keychain.save(session)
    #expect(try keychain.read() == session)

    // The item as the system holds it.
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: SystemSessionKeychain.service,
      kSecAttrSynchronizable: kSecAttrSynchronizableAny,
      kSecMatchLimit: kSecMatchLimitAll,
      kSecReturnAttributes: true,
    ]
    var found: CFTypeRef?
    #expect(SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess)
    let items = try #require(found as? [[CFString: Any]])
    #expect(items.count == 1)
    let item = try #require(items.first)
    #expect(item[kSecAttrAccessGroup] as? String == accessGroup)
    #expect(item[kSecAttrAccessible] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    #expect((item[kSecAttrSynchronizable] as? Bool ?? false) == false)
    // The item is named for the instance and the user.
    #expect(item[kSecAttrAccount] as? String == "7 http://10.0.0.5:8080/family")

    // A second session takes the place of the first: a device holds one session at most.
    let other = Session(instance: instance, token: "another-token", userID: "8")
    try keychain.save(other)
    #expect(try keychain.read() == other)
    #expect(SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess)
    #expect((found as? [[CFString: Any]])?.count == 1)

    try keychain.delete()
    #expect(try keychain.read() == nil)
  }

  @Test("After a sign-out, the Keychain item and the database file are gone from the device")
  @MainActor
  func signOutClearsTheDevice() async throws {
    let accessGroup = try #require(Bundle.main.object(forInfoDictionaryKey: "WishboneKeychainAccessGroup") as? String)
    let keychain = SystemSessionKeychain(accessGroup: accessGroup)
    // The bundle has no test server, so the instance can't be reached. The device is cleared all the same.
    let instance = try #require(InstanceAddress("http://127.0.0.1:9"))
    try keychain.save(Session(instance: instance, token: "a-token-for-the-test", userID: "7"))
    // The bundle can't link `TestSupport`, so the device's storage is a folder of its own in the app's caches.
    let storage = URL.cachesDirectory.appending(path: "SignOutTest-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: storage) }
    let sessions = storage.appending(path: "Sessions", directoryHint: .isDirectory)

    let device = Device(
      Device.Setup(
        userAgent: UserAgent(version: "1.0", isPad: false), keychain: keychain, storage: .folder(storage)))
    #expect(device.session != nil)
    let folders = try FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)
    #expect(folders.count == 1)
    let file = try #require(folders.first).appending(path: "database.sqlite")
    #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))

    await device.signOut()

    #expect(device.session == nil)
    #expect(device.signInState == .signedOutUnreachable(instance))
    #expect(try keychain.read() == nil)
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: SystemSessionKeychain.service,
      kSecAttrSynchronizable: kSecAttrSynchronizableAny,
    ]
    #expect(SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound)
    #expect(!FileManager.default.fileExists(atPath: sessions.path(percentEncoded: false)))
  }
}
