import Foundation
import Network
import Security

/// A TLS identity for `localhost` that no device trusts: a self-signed certificate, and its key. The network
/// conditioner serves HTTPS with it, as an instance does whose certificate comes from a private certificate
/// authority that the device doesn't have.
///
/// It is made once for each test process, with `openssl`, so only macOS has it.
enum UntrustedCertificate {
  struct Unavailable: Error, CustomStringConvertible {
    let reason: String

    var description: String {
      "The untrusted certificate can't be made: \(reason)"
    }
  }

  /// The passphrase of the PKCS #12 bundle, which never leaves the test process.
  private static let passphrase = "wishbone"

  /// The identity, for the local side of a TLS connection.
  static func identity() throws -> sec_identity_t {
    let bundle = try bundle.get()
    var items: CFArray?
    let options: [CFString: Any] = [kSecImportExportPassphrase: passphrase, kSecImportToMemoryOnly: true]
    let status = SecPKCS12Import(bundle as CFData, options as CFDictionary, &items)
    guard status == errSecSuccess else { throw Unavailable(reason: "the import failed with \(status)") }
    guard let first = (items as? [[String: Any]])?.first,
      let found = first[kSecImportItemIdentity as String],
      CFGetTypeID(found as CFTypeRef) == SecIdentityGetTypeID()
    else { throw Unavailable(reason: "the bundle has no identity") }
    // The type ID says that it is an identity.
    guard let identity = sec_identity_create(found as! SecIdentity) else {
      throw Unavailable(reason: "Network can't use the identity")
    }
    return identity
  }

  /// The certificate and its key, as a PKCS #12 bundle. A static `let` is made once, and safely across threads.
  private static let bundle: Result<Data, Unavailable> = makeBundle()

  private static func makeBundle() -> Result<Data, Unavailable> {
    #if os(macOS)
      // RSA, because the system's PKCS #12 import can't read the key of an EC certificate that LibreSSL writes.
      let script = """
        /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/stdout -out /dev/stdout -days 2 \
        -subj /CN=localhost 2>/dev/null | /usr/bin/openssl pkcs12 -export -passout pass:\(passphrase)
        """
      let process = Process()
      process.executableURL = URL(filePath: "/bin/sh")
      process.arguments = ["-c", script]
      process.environment = [:]
      let output = Pipe()
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      do {
        try process.run()
      } catch {
        return .failure(Unavailable(reason: "the shell didn't start: \(error)"))
      }
      let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
      process.waitUntilExit()
      guard process.terminationStatus == 0, !data.isEmpty else {
        return .failure(Unavailable(reason: "openssl ended with status \(process.terminationStatus)"))
      }
      return .success(data)
    #else
      return .failure(Unavailable(reason: "only macOS has openssl"))
    #endif
  }
}
