import Foundation
import Security

/// The session keychain: where the device keeps its one session. See "Where the session lives" in `docs/spec.md`.
public protocol SessionKeychain: Sendable {
  /// The session that the device holds. Nil when it holds none.
  func read() throws(SessionKeychainError) -> Session?

  /// Keeps the session, in place of any other. A device holds one session at most.
  func save(_ session: Session) throws(SessionKeychainError)

  /// Forgets the session.
  func delete() throws(SessionKeychainError)
}

/// The Keychain refused a call.
///
/// Diagnostics: never. The event vocabulary has no case for it.
public struct SessionKeychainError: Error, Sendable, Equatable {
  /// The `OSStatus` of the call that failed.
  public let status: Int32

  public init(status: Int32) {
    self.status = status
  }
}

/// The session keychain in the system's Keychain.
///
/// - One item holds the instance address, the token, and the user's ID, so the address and the token stay in step.
///   The item is named for the instance and the user.
/// - The item is in the access group that the app, the share extension, and the widget extension share.
/// - It never leaves the device: it is "this device only", and it is not in iCloud Keychain.
/// - It is readable after the first unlock, because the widget and background refresh run while the device is
///   locked.
public struct SystemSessionKeychain: SessionKeychain {
  /// The service of the item.
  public static let service = "wishbone.session"

  private let accessGroup: String

  /// `accessGroup` is the Keychain access group that the three targets share, with the team's prefix.
  public init(accessGroup: String) {
    self.accessGroup = accessGroup
  }

  /// What every call names: the items of the service, in the shared access group, that stay on the device.
  private var items: [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.service,
      kSecAttrAccessGroup: accessGroup,
      kSecAttrSynchronizable: false,
      kSecUseDataProtectionKeychain: true,
    ]
  }

  public func read() throws(SessionKeychainError) -> Session? {
    var query = items
    query[kSecMatchLimit] = kSecMatchLimitOne
    query[kSecReturnData] = true
    var found: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &found)
    guard status != errSecItemNotFound else { return nil }
    guard status == errSecSuccess else { throw SessionKeychainError(status: status) }
    // An item that doesn't read as a session is no session. The next sign-in replaces it.
    guard let data = found as? Data else { return nil }
    return try? JSONDecoder().decode(Session.self, from: data)
  }

  public func save(_ session: Session) throws(SessionKeychainError) {
    try delete()
    var item = items
    item[kSecAttrAccount] = "\(session.userID) \(session.instance)"
    item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    // The session is three short strings, which always encode.
    item[kSecValueData] = (try? JSONEncoder().encode(session)) ?? Data()
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw SessionKeychainError(status: status) }
  }

  public func delete() throws(SessionKeychainError) {
    let status = SecItemDelete(items as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw SessionKeychainError(status: status) }
  }
}
