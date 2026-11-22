import Foundation
import SwiftUI

/// The license notices that the app must show: its own MPL-2.0 notice, then the full license text of each package
/// that the app ships. See `docs/screens/acknowledgements.md`.
///
/// The texts are in the app, so the screen needs no connection: `Acknowledgements` reads them from the module's
/// resources. The notices are the licenses' own words, and are not translated.
///
/// **Provisional.** A plain scrolling text screen, with a heading for each package.
struct AcknowledgementsScreen: View {
  /// A readable width in a wide window.
  @ScaledMetric(relativeTo: .body) private var readableWidth: CGFloat = 640

  /// What ends a paragraph of a notice: an empty line. It shows no words.
  private static let paragraphBreak = "\n\n"

  /// A notice, one text for each of its paragraphs. The accessibility audit reads one text of several paragraphs as
  /// clipped at larger sizes, where all of it shows. The texts never change, so a paragraph's place is its identity.
  private static func paragraphs(of notice: String) -> some View {
    let paragraphs = notice.components(separatedBy: paragraphBreak).filter { !$0.isEmpty }
    return VStack(alignment: .leading, spacing: 12) {
      ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
        Text(paragraph)
      }
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Self.paragraphs(of: Acknowledgements.notice)
        Text("Wishbone uses these open source packages.", bundle: #bundle)
        ForEach(Acknowledgements.packages) { package in
          VStack(alignment: .leading, spacing: 8) {
            Text(package.name)
              .font(.headline)
              .accessibilityAddTraits(.isHeader)
            Self.paragraphs(of: package.license)
              .font(.footnote)
          }
        }
      }
      .textSelection(.enabled)
      .frame(maxWidth: readableWidth, alignment: .leading)
      .frame(maxWidth: .infinity)
      .padding()
    }
    .navigationTitle(Text("Acknowledgements", bundle: #bundle))
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }
}
