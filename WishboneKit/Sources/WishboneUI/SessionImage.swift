import SwiftUI
import WishboneAPI
import WishboneSession

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

extension EnvironmentValues {
  /// The image cache of the session that the window shows. Nil while the window shows no session.
  @Entry var sessionImages: ImageCache? = nil
}

/// An image of the instance, from the session's image cache, filled into its frame as it is, with no tint and no
/// overlay. Until the image comes, and when there is none, it shows the placeholder: the tile or the initials, never
/// a broken-image mark. See "Images" in `docs/spec.md`.
///
/// It is a picture beside words that say the same, so VoiceOver skips it.
struct SessionImage<Placeholder: View>: View {
  let image: ImageSummary?
  @ViewBuilder let placeholder: () -> Placeholder

  @Environment(\.sessionImages) private var images
  @State private var shown: Shown?

  /// The picture that shows, with the address that it came from.
  private struct Shown {
    let url: String
    let picture: Image
  }

  var body: some View {
    Group {
      if let shown, shown.url == image?.url {
        shown.picture
          .resizable()
          .scaledToFill()
      } else {
        placeholder()
      }
    }
    .accessibilityHidden(true)
    .task(id: image?.url) {
      guard let image, let images else {
        shown = nil
        return
      }
      guard let data = await images.data(for: image), let picture = await Picture.from(data) else { return }
      shown = Shown(url: image.url, picture: picture)
    }
  }

}

/// The picture of an image's bytes, made off the main actor.
private enum Picture {
  /// Nil for bytes that are not an image.
  @concurrent
  static func from(_ data: Data) async -> Image? {
    #if canImport(UIKit)
      guard let image = UIImage(data: data) else { return nil }
      return Image(uiImage: image.preparingForDisplay() ?? image)
    #else
      guard let image = NSImage(data: data) else { return nil }
      return Image(nsImage: image)
    #endif
  }
}
