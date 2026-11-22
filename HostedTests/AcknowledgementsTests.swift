import Testing
import WishboneUI

/// The Acknowledgements screen's texts, in the app's own build: the module's resources must be in the bundle, and
/// decode. See "Source code and Acknowledgements" in `docs/spec.md`, and `docs/screens/acknowledgements.md`.
@Suite("Acknowledgements", .timeLimit(.minutes(1)))
@MainActor
struct AcknowledgementsTests {
  @Test("The built module has the app's notice and the license text of each package it ships")
  func builtModuleHasTheTexts() {
    // A fitness test holds the words to the README. This holds that the built bundle has them at all.
    #expect(Acknowledgements.notice.contains("Mozilla Public License, v. 2.0"))

    // A missing or broken Acknowledgements.json would show no packages. A fitness test holds the names to the pins.
    let packages = Acknowledgements.packages
    #expect(!packages.isEmpty)
    #expect(Set(packages.map(\.name)).count == packages.count, "A package is in the file twice.")
    for package in packages {
      #expect(!package.name.isEmpty)
      #expect(package.license.count > 500, "\(package.name) has no full license text.")
    }
  }
}
