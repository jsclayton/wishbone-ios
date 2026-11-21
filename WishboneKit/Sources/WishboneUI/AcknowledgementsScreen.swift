import Foundation
import SwiftUI

/// The license notices that the app must show: its own MPL-2.0 notice, then the full license text of each package
/// that the app ships. See `docs/screens/acknowledgements.md`.
///
/// The texts are in the app, so the screen needs no connection. The package texts come from `Acknowledgements.json`,
/// which `just build` makes from the pinned packages. The notices are the licenses' own words, and are not
/// translated.
///
/// **Provisional.** A plain scrolling text screen, with a heading for each package.
struct AcknowledgementsScreen: View {
  /// One package that the app ships: its name, and its license's full text.
  struct Package: Decodable, Identifiable {
    let name: String
    let license: String

    var id: String { name }
  }

  /// The app's own notice, as the README carries it (see ADR 0009).
  static let notice = """
    Copyright © 2026 John Clayton and contributors

    This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was \
    not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
    """

  /// The file of the packages, in the module's resources. It names a file, and shows no words.
  private static let fileName = "Acknowledgements"
  private static let fileType = "json"

  /// The packages, from the module's resources, in the order of the file.
  static let packages: [Package] = {
    guard let url = #bundle.url(forResource: fileName, withExtension: fileType),
      let data = try? Data(contentsOf: url)
    else { return [] }
    return (try? JSONDecoder().decode([Package].self, from: data)) ?? []
  }()

  /// A readable width in a wide window.
  @ScaledMetric(relativeTo: .body) private var readableWidth: CGFloat = 640

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Text(Self.notice)
        Text("Wishbone uses these open source packages.", bundle: #bundle)
        ForEach(Self.packages) { package in
          VStack(alignment: .leading, spacing: 8) {
            Text(package.name)
              .font(.headline)
              .accessibilityAddTraits(.isHeader)
            Text(package.license)
              .font(.footnote)
          }
        }
      }
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
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
