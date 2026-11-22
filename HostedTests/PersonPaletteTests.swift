import Testing
import UIKit
import WishboneUI

/// The person palette: one color for each user, from their ID, the same on every device, with white initials that
/// pass the contrast rule on every color. See "A color for each person" and "Accessibility" in `docs/spec.md`.
@Suite("The person palette", .timeLimit(.minutes(1)))
@MainActor
struct PersonPaletteTests {
  @Test("One ID gives one color, every time, and the same on every device")
  func oneColorForOneID() {
    // The colors that these IDs get are fixed: a hash that changed with the launch, or with the device, would move
    // them.
    let fixed: [String: PersonPalette.Hue] = [
      "1": .blue, "2": .pink, "12": .red, "42": .orange, "0193a4e2-7c1d-7b3e-9f00-5a6b7c8d9e0f": .purple,
    ]
    for (id, hue) in fixed {
      #expect(PersonPalette.hue(forUserID: id) == hue, "\(id)")
    }
    for id in (1...200).map(String.init) {
      #expect(PersonPalette.hue(forUserID: id) == PersonPalette.hue(forUserID: id), "\(id)")
    }
    // The IDs spread over the whole palette.
    let used = Set((1...200).map { PersonPalette.hue(forUserID: String($0)) })
    #expect(used == Set(PersonPalette.Hue.allCases))
  }

  @Test("White initials pass 4.5:1 on every palette color, in light, dark, and Increase Contrast")
  func contrast() throws {
    let settings: [(String, UITraitCollection)] = [
      ("light", Self.traits(.light, .normal)),
      ("dark", Self.traits(.dark, .normal)),
      ("light, Increase Contrast", Self.traits(.light, .high)),
      ("dark, Increase Contrast", Self.traits(.dark, .high)),
    ]
    for hue in PersonPalette.Hue.allCases {
      for (setting, traits) in settings {
        let fill = hue.uiColor.resolvedColor(with: traits)
        let ratio = try Self.contrast(of: .white, on: fill)
        #expect(ratio >= 4.5, "\(hue) in \(setting): \(ratio)")
      }
    }
  }

  private static func traits(_ style: UIUserInterfaceStyle, _ contrast: UIAccessibilityContrast) -> UITraitCollection {
    UITraitCollection(mutations: { traits in
      traits.userInterfaceStyle = style
      traits.accessibilityContrast = contrast
    })
  }

  /// The contrast ratio of two opaque colors, as WCAG 2.1 defines it.
  private static func contrast(of text: UIColor, on fill: UIColor) throws -> Double {
    let (first, second) = (try luminance(of: text), try luminance(of: fill))
    return (max(first, second) + 0.05) / (min(first, second) + 0.05)
  }

  private static func luminance(of color: UIColor) throws -> Double {
    var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    try #require(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
    #expect(alpha == 1, "The color is not opaque.")
    func linear(_ channel: CGFloat) -> Double {
      let value = Double(min(max(channel, 0), 1))
      return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }
}
