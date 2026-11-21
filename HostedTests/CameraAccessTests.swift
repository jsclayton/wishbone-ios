import AVFoundation
import Testing
import WishboneUI

/// What Scan QR code shows for the camera's state. See "The signed-out screen" in `docs/spec.md`, and "States" in
/// `docs/screens/signed-out.md`.
@Suite("The camera's state, on the signed-out screen", .timeLimit(.minutes(1)))
@MainActor
struct CameraAccessTests {
  @Test("Allowed opens the scanner, denied says why and offers Open Settings, and not available says so")
  func whatScanShows() {
    // Allowed, or not asked yet: the system asks at the first tap.
    for status in [AVAuthorizationStatus.authorized, .notDetermined] {
      let allowed = CameraAccess(authorization: status, isSupported: true)
      #expect(allowed == .allowed)
      #expect(allowed.canScan)
      #expect(allowed.reason == nil)
      #expect(!allowed.offersSettings)
    }

    for status in [AVAuthorizationStatus.denied, .restricted] {
      let denied = CameraAccess(authorization: status, isSupported: true)
      #expect(denied == .denied)
      #expect(!denied.canScan)
      #expect(
        denied.reason
          == "Wishbone needs the camera to scan a QR code. You can turn it on in Settings, or paste a link.")
      #expect(denied.offersSettings)
    }

    // A device with no camera to scan with, whatever the permission says. Settings can't help.
    for status in [AVAuthorizationStatus.authorized, .notDetermined, .denied] {
      let notAvailable = CameraAccess(authorization: status, isSupported: false)
      #expect(notAvailable == .notAvailable)
      #expect(!notAvailable.canScan)
      #expect(notAvailable.reason == "This device has no camera to scan with. Paste a link.")
      #expect(!notAvailable.offersSettings)
    }

    // The simulator has no camera, so the signed-out screen there shows the "no camera" state.
    #expect(CameraAccess.current == .notAvailable)
  }
}
