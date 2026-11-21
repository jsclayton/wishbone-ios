#if os(iOS)
  import AVFoundation
  import Foundation
  import VisionKit

  /// Whether the scanner can use the camera, and what Scan QR code shows for it. See "The signed-out screen" in
  /// `docs/spec.md`.
  ///
  /// Paste does everything that the scanner does, so a device with no camera, or with the camera denied, can still
  /// sign in.
  public enum CameraAccess: Sendable, Equatable {
    /// The person allowed the camera, or the system has not asked yet. Scan QR code opens the scanner.
    case allowed

    /// The person denied the camera. Settings can turn it on.
    case denied

    /// A restriction, such as Screen Time or a device manager, holds the camera back. The app's page in Settings
    /// can't turn it on, so the screen offers no Open Settings.
    case restricted

    /// The device has no camera that the system's data scanner can use, as in the simulator.
    case notAvailable

    /// The access for the camera's permission and for whether the device can scan.
    public init(authorization: AVAuthorizationStatus, isSupported: Bool) {
      guard isSupported else {
        self = .notAvailable
        return
      }
      switch authorization {
      case .authorized, .notDetermined:
        self = .allowed
      case .denied:
        self = .denied
      case .restricted:
        self = .restricted
      @unknown default:
        self = .denied
      }
    }

    /// The access that the device has now.
    public static var current: CameraAccess {
      CameraAccess(
        authorization: AVCaptureDevice.authorizationStatus(for: .video),
        isSupported: DataScannerViewController.isSupported
      )
    }

    /// Whether Scan QR code can open the scanner.
    public var canScan: Bool {
      self == .allowed
    }

    /// Why Scan QR code can't open the scanner. Nil when it can.
    public var reason: String? {
      switch self {
      case .allowed:
        nil
      case .denied:
        String(
          localized: "Wishbone needs the camera to scan a QR code. You can turn it on in Settings, or paste a link.",
          bundle: #bundle
        )
      case .restricted:
        String(
          localized: "The camera is turned off on this device, so Wishbone can't scan. Paste a link.", bundle: #bundle)
      case .notAvailable:
        String(localized: "This device has no camera to scan with. Paste a link.", bundle: #bundle)
      }
    }

    /// Whether the screen offers Open Settings, which can turn the camera on.
    public var offersSettings: Bool {
      self == .denied
    }
  }
#endif
