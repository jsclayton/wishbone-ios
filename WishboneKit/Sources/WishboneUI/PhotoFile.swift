import Foundation
import SwiftUI

#if os(iOS)
  import UIKit
#endif

/// A photo that the person took or chose, ready to upload: the bytes of a JPEG, and how it shows on the form.
///
/// The server takes a JPEG, PNG, GIF, or WebP of at most 10 MiB, and keeps at most 1200 px on the longest side. A
/// photo from the camera or the library is often HEIC, and larger. So the app sends a JPEG of at most 2400 px. A
/// file that the device can't read as an image goes as it is, and the server's answer says why it can't be used.
struct PhotoFile {
  let data: Data
  let preview: Image?

  /// The longest side that the app sends.
  private static let longestSide: CGFloat = 2400

  init(_ data: Data) {
    #if os(iOS)
      if let image = UIImage(data: data) {
        self = PhotoFile(image)
        return
      }
    #endif
    self.data = data
    preview = nil
  }

  #if os(iOS)
    init(_ image: UIImage) {
      let scale = min(1, Self.longestSide / max(image.size.width, image.size.height, 1))
      let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
        image.draw(in: CGRect(origin: .zero, size: size))
      }
      data = scaled.jpegData(compressionQuality: 0.85) ?? Data()
      preview = Image(uiImage: scaled)
    }

    /// Whether the device has a camera to take a photo with.
    static var canTakePhotos: Bool {
      UIImagePickerController.isSourceTypeAvailable(.camera)
    }
  #endif
}

#if os(iOS)
  /// The system camera, for Take a photo. It hands back the photo, and closes.
  struct CameraPicker: UIViewControllerRepresentable {
    let take: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
      let picker = UIImagePickerController()
      picker.sourceType = .camera
      picker.delegate = context.coordinator
      return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
      Coordinator(take: take, dismiss: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
      let take: (UIImage) -> Void
      let dismiss: () -> Void

      init(take: @escaping (UIImage) -> Void, dismiss: @escaping () -> Void) {
        self.take = take
        self.dismiss = dismiss
      }

      func imagePickerController(
        _ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
      ) {
        if let image = info[.originalImage] as? UIImage { take(image) }
        dismiss()
      }

      func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        dismiss()
      }
    }
  }
#endif
