import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A photo that the user took or chose on the Add screen: the bytes that go to search and, on Add, to
/// `POST /images`. It is the item's image. It goes only to the instance. See "The empty Add screen" and "What the add
/// form holds" in `docs/spec.md`.
///
/// The server takes a JPEG, PNG, GIF, or WebP of at most 10 MiB, and keeps at most 1200 px on the longest side. A
/// photo from the camera or the library is often HEIC, and larger. So the app sends a JPEG of at most 2400 px, under
/// the limit, with none of the original's metadata. A file that the device can't make that JPEG of is not a photo:
/// nothing of it is sent, so no file with its metadata ever leaves the device.
public struct Photo: Sendable, Equatable, Identifiable {
  /// The most bytes that the server takes in one image.
  public static let byteLimit = 10 << 20

  /// The longest side that the app sends.
  public static let longestSide = 2400

  /// The longest side that the share extension sends: the most that the server keeps. The extension has a memory
  /// limit of about 120 MB, and a decode for 2400 px of a 48 MP JPEG takes about 100 MB of it. For 1200 px, the
  /// decoder reads the file at a quarter of its size, so the peak stays near 30 MB.
  public static let sharedLongestSide = 1200

  public let id: UUID

  /// The bytes that are sent. From a file, always the JPEG that the device made of it.
  public let data: Data

  /// The title when no guess comes back: "Photo from {date}". The words come from the String Catalog, in
  /// `WishboneUI`.
  public let untitled: String

  /// A photo of the bytes, as they are sent.
  public init(data: Data, untitled: String) {
    id = UUID()
    self.data = data
    self.untitled = untitled
  }

  /// The photo of a file from the camera or the photo picker, as a JPEG under the limit. `untitled` gets the date
  /// that the photo was taken, from its metadata, or now. Nil when the device can't make the JPEG: the file is
  /// never sent as it is.
  public init?(file: Data, now: Date = .now, untitled: (Date) -> String) {
    guard let jpeg = Self.jpeg(of: file) else { return nil }
    self.init(data: jpeg, untitled: untitled(Self.dateTaken(of: file) ?? now))
  }

  /// The photo of an image file that another app shared, as a JPEG of at most `longestSide` px, under the limit.
  /// The file is read from where it is, and decoded only at the size that is sent, so the image is made smaller
  /// before it is held: the share extension never holds the file's bytes, or its full-size image. `untitled` gets
  /// the date that the photo was taken, from its metadata, or now. Nil when the device can't make the JPEG.
  public init?(fileAt url: URL, longestSide side: Int, now: Date = .now, untitled: (Date) -> String) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
      let jpeg = Self.jpeg(of: source, longestSide: side)
    else { return nil }
    self.init(data: jpeg, untitled: untitled(Self.dateTaken(of: source) ?? now))
  }

  /// Two photos are the same photo when they are one pick: the form compares them on every change.
  public static func == (first: Photo, second: Photo) -> Bool {
    first.id == second.id
  }

  /// The file as a JPEG of at most `longestSide` px, turned upright, under `byteLimit`, with no metadata. Nil when
  /// the device can't read the file as an image.
  public static func jpeg(of file: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(file as CFData, nil) else { return nil }
    return jpeg(of: source, longestSide: longestSide)
  }

  /// The source's first image as a JPEG of at most `longestSide` px, turned upright, under `byteLimit`, with no
  /// metadata.
  private static func jpeg(of source: CGImageSource, longestSide: Int) -> Data? {
    guard CGImageSourceGetCount(source) > 0 else { return nil }
    var side = longestSide
    var quality = 0.85
    while side >= 300 {
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: side,
        kCGImageSourceShouldCacheImmediately: true,
      ]
      guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
      let output = NSMutableData()
      guard
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
      else { return nil }
      CGImageDestinationAddImage(
        destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { return nil }
      if output.length <= byteLimit { return output as Data }
      // Rarely needed: a photo of fine noise can be large even at this size.
      quality = max(0.5, quality - 0.15)
      side = side * 3 / 4
    }
    return nil
  }

  /// A small picture of the photo, turned upright, for the form. Nil when the device can't read it.
  public func preview(longestSide side: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: side,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  /// When the photo was taken, from its EXIF metadata. Nil when the file says nothing. The EXIF time has no zone,
  /// so it is read in the device's.
  static func dateTaken(of file: Data) -> Date? {
    CGImageSourceCreateWithData(file as CFData, nil).flatMap(dateTaken(of:))
  }

  private static func dateTaken(of source: CGImageSource) -> Date? {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
      let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String
    else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    return formatter.date(from: text)
  }
}
