import SwiftUI

#if os(iOS)
  import UIKit
#endif

/// The person palette: a color for each user, made from the user's ID, from a fixed palette of system colors. It
/// is the same on every device, with no server change. See "A color for each person" in `docs/spec.md`.
///
/// - The color comes from a hash of the ID's bytes that never changes (FNV-1a), never from Swift's `hashValue`,
///   which differs in each launch.
/// - Each color is the system color as Increase Contrast resolves it in light mode, and it stays that color in
///   every appearance. White initials on it pass 4.5:1 in light, dark, and Increase Contrast. The brighter colors
///   that dark mode gives would fail that.
/// - The palette leaves out the colors on which white initials fail: yellow, green, and teal.
/// - A color never carries meaning. A name always sits beside it.
///
/// **Provisional.** The palette. Plain default: as below.
public enum PersonPalette {
  /// The palette's colors, in their fixed order. A new color goes at the end, and moves most users' colors, so the
  /// order changes only on purpose.
  public enum Hue: String, CaseIterable, Sendable {
    case red, orange, mint, cyan, blue, indigo, purple, pink, brown
  }

  /// The user's color, from their ID. One ID gives one color, every time, on every device.
  public static func hue(forUserID id: String) -> Hue {
    // FNV-1a, 64 bits.
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in id.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return Hue.allCases[Int(hash % UInt64(Hue.allCases.count))]
  }

  /// The user's color, to fill an avatar.
  static func color(forUserID id: String) -> Color {
    color(of: hue(forUserID: id))
  }

  /// One color of the palette.
  static func color(of hue: Hue) -> Color {
    #if os(iOS)
      Color(uiColor: hue.uiColor)
    #else
      Color.accentColor
    #endif
  }
}

#if os(iOS)
  extension PersonPalette.Hue {
    /// The color, the same in every appearance: the system color as Increase Contrast resolves it in light mode.
    public var uiColor: UIColor {
      let fixed = UITraitCollection(mutations: { traits in
        traits.userInterfaceStyle = .light
        traits.accessibilityContrast = .high
      })
      let color = system.resolvedColor(with: fixed)
      return UIColor { _ in color }
    }

    private var system: UIColor {
      switch self {
      case .red: .systemRed
      case .orange: .systemOrange
      case .mint: .systemMint
      case .cyan: .systemCyan
      case .blue: .systemBlue
      case .indigo: .systemIndigo
      case .purple: .systemPurple
      case .pink: .systemPink
      case .brown: .systemBrown
      }
    }
  }
#endif
