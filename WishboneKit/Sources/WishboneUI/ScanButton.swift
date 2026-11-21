#if os(iOS)
  import AVFoundation
  import SwiftUI
  import VisionKit
  import WishboneAPI
  import WishboneSession

  /// Scan QR code, the main button of the signed-out screen. When the camera is denied or not available, it says
  /// why, and offers Open Settings when Settings can help. Paste still works. See "The signed-out screen" in
  /// `docs/spec.md`.
  struct ScanButton: View {
    @Environment(Device.self) private var device
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    /// Whether the scanner can use the camera. It is read again each time the app comes back, as from Settings.
    @State private var camera = CameraAccess.current

    /// Whether the scanner shows.
    @State private var isScanning = false

    var body: some View {
      VStack(spacing: 16) {
        Button {
          Task { await scan() }
        } label: {
          Text("Scan QR code", bundle: #bundle)
            .foregroundStyle(Color(.onAccent))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!camera.canScan)

        if let reason = camera.reason {
          Text(reason)
            .font(.footnote)
            .multilineTextAlignment(.center)
        }
        if camera.offersSettings {
          Button {
            if let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) }
          } label: {
            Text("Open Settings", bundle: #bundle)
              .frame(minHeight: 44)
          }
        }
      }
      .onChange(of: scenePhase) {
        if scenePhase == .active { camera = .current }
      }
      .fullScreenCover(isPresented: $isScanning) {
        Scanner { link in
          // A scanned login link closes the cover, and starts the same sign-in as a paste.
          isScanning = false
          Task { await device.signIn(scanned: link) }
        }
      }
    }

    /// Opens the scanner. The first tap asks for the camera, and the scanner opens only if the person allows it.
    private func scan() async {
      if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
        _ = await AVCaptureDevice.requestAccess(for: .video)
      }
      camera = .current
      isScanning = camera.canScan
    }
  }

  /// The scanner: the system's data scanner in a full-screen cover, with Cancel and one line of help. See "The
  /// scanner" in `docs/screens/signed-out.md`.
  ///
  /// It reacts only to a login link, and ignores any other QR code. The link is a secret until it is used, so the
  /// scanner never logs what it reads.
  struct Scanner: View {
    /// Called once, with the first login link that the camera sees.
    let scanned: (LoginLink) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
      NavigationStack {
        DataScanner(scanned: scanned)
          .ignoresSafeArea()
          .safeAreaInset(edge: .bottom) {
            Text("Point the camera at the QR code of your login link.", bundle: #bundle)
              .multilineTextAlignment(.center)
              .padding()
              .frame(maxWidth: .infinity)
              .background(.regularMaterial)
          }
          .toolbar {
            // Cancel is the scanner's first element.
            ToolbarItem(placement: .cancellationAction) {
              Button {
                dismiss()
              } label: {
                Text("Cancel", bundle: #bundle)
              }
            }
          }
      }
    }
  }

  /// The system's data scanner, for QR codes only.
  private struct DataScanner: UIViewControllerRepresentable {
    let scanned: (LoginLink) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
      let scanner = DataScannerViewController(
        recognizedDataTypes: [.barcode(symbologies: [.qr])],
        qualityLevel: .balanced,
        recognizesMultipleItems: true,
        isHighFrameRateTrackingEnabled: false,
        isHighlightingEnabled: true
      )
      scanner.delegate = context.coordinator
      return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
      context.coordinator.scanned = scanned
      guard !scanner.isScanning, !context.coordinator.isDone else { return }
      // It throws only when the camera is denied or not available, and the signed-out screen opens no scanner then.
      try? scanner.startScanning()
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
      scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
      Coordinator(scanned: scanned)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
      var scanned: (LoginLink) -> Void

      /// Whether a login link was found. The scanner then reports nothing more.
      private(set) var isDone = false

      init(scanned: @escaping (LoginLink) -> Void) {
        self.scanned = scanned
      }

      func dataScanner(
        _ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]
      ) {
        guard !isDone else { return }
        for item in addedItems {
          guard case .barcode(let barcode) = item, let payload = barcode.payloadStringValue,
            let link = LoginLink(payload)
          else { continue }
          isDone = true
          dataScanner.stopScanning()
          scanned(link)
          return
        }
      }
    }
  }
#endif
