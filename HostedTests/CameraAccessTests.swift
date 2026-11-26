import AVFoundation
import Testing
import WishboneUI

/// What Scan QR code shows for the camera's state. See "The signed-out screen" in `docs/spec.md`, and "States" in
/// `docs/screens/signed-out.md`.
@Suite("The camera's state, on the signed-out screen", .timeLimit(.minutes(1)))
@MainActor
struct CameraAccessTests {
  @Test("Allowed opens the scanner, denied says why and offers Open Settings, and restricted and not available say so")
  func whatScanShows() {
    // Allowed, or not asked yet: the system asks at the first tap.
    for status in [AVAuthorizationStatus.authorized, .notDetermined] {
      let allowed = CameraAccess(authorization: status, isSupported: true)
      #expect(allowed == .allowed)
      #expect(allowed.canScan)
      #expect(allowed.reason == nil)
      #expect(!allowed.offersSettings)
    }

    let denied = CameraAccess(authorization: .denied, isSupported: true)
    #expect(denied == .denied)
    #expect(!denied.canScan)
    #expect(
      denied.reason
        == "Wishbone needs the camera to scan a QR code. You can turn it on in Settings, or paste a link.")
    #expect(denied.offersSettings)

    // A restriction, such as Screen Time, says why, and offers no Open Settings: the app's page there can't help.
    let restricted = CameraAccess(authorization: .restricted, isSupported: true)
    #expect(restricted == .restricted)
    #expect(!restricted.canScan)
    #expect(restricted.reason == "The camera is turned off on this device, so Wishbone can't scan. Paste a link.")
    #expect(!restricted.offersSettings)

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

  @Test("Take a photo: denied says why and offers Open Settings, restricted says so, and no camera has no row")
  func whatTakeAPhotoShows() {
    let allowed = CameraAccess(authorization: .notDetermined, isSupported: true)
    #expect(allowed.showsTakeAPhoto)
    #expect(allowed.photoReason == nil)

    let denied = CameraAccess(authorization: .denied, isSupported: true)
    #expect(denied.showsTakeAPhoto)
    #expect(
      denied.photoReason
        == "Wishbone needs the camera to take a photo. You can turn it on in Settings, or choose a photo.")
    #expect(denied.offersSettings)

    let restricted = CameraAccess(authorization: .restricted, isSupported: true)
    #expect(restricted.showsTakeAPhoto)
    #expect(
      restricted.photoReason
        == "The camera is turned off on this device, so Wishbone can't take a photo. Choose a photo.")
    #expect(!restricted.offersSettings)

    // A device with no camera: Choose a photo is the way in.
    let notAvailable = CameraAccess(authorization: .authorized, isSupported: false)
    #expect(!notAvailable.showsTakeAPhoto)
    #expect(notAvailable.photoReason == nil)
  }
}
