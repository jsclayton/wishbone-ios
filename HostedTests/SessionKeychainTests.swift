import Foundation
import Security
import Testing
import WishboneAPI

/// The session keychain's item, in the system's Keychain, with the app's entitlements. See "Where the session
/// lives" in `docs/spec.md`.
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
}
