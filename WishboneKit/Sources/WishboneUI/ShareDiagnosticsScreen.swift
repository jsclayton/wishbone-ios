import Foundation
import SwiftUI

/// The diagnostics switch, as the screens see it. The app gives it from `WishboneDiagnostics`, which no module that
/// an extension links may import. See "Diagnostics" in `docs/architecture.md`.
public protocol DiagnosticsSwitch: AnyObject, Sendable {
  /// Whether diagnostics are on for this device. Off deletes what is not sent and the diagnostics ID. On makes a new
  /// ID.
  var isOn: Bool { get set }

  /// The signed-out screen has shown the notice, so the SDK may start.
  func noticeShown()
}

extension EnvironmentValues {
  /// The device's diagnostics switch. Only the app has one.
  @Entry public var diagnostics: (any DiagnosticsSwitch)? = nil
}

/// The Share diagnostics screen: one switch, with what is sent and what never is. See
/// `docs/screens/share-diagnostics.md`.
///
/// It is a sheet from the notice line of the signed-out screen, and pushed from Settings.
///
/// **Provisional.** A system form with a toggle, a footer paragraph, and a link. As a sheet, it has Done.
struct ShareDiagnosticsScreen: View {
  /// Where the screen shows.
  enum Place {
    case sheet
    case pushed
  }

  let place: Place

  @Environment(\.diagnostics) private var diagnostics
  @Environment(\.dismiss) private var dismiss

  /// The privacy policy, from the build's `WISHBONE_PRIVACY_URL`.
  private static let privacyPolicy: URL? = {
    guard let text = Bundle.main.object(forInfoDictionaryKey: "WishbonePrivacyURL") as? String, !text.isEmpty else {
      return nil
    }
    return URL(string: text)
  }()

  var body: some View {
    // Pushed from Settings, the bar names the screen. As a sheet, the bar holds only Done: a title there is cut short
    // in a longer language, and the switch's words already name the screen.
    switch place {
    case .pushed:
      form
        .navigationTitle(Text("Share diagnostics", bundle: #bundle))
        #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
        #endif
    case .sheet:
      form
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button {
              dismiss()
            } label: {
              Text("Done", bundle: #bundle)
            }
          }
        }
    }
  }

  private var form: some View {
    Form {
      Section {
        Toggle(isOn: isOn) {
          Text("Share diagnostics", bundle: #bundle)
        }
      } footer: {
        // The paragraph is read after the switch. The primary color: the system's secondary gray of a footer is
        // below 4.5:1.
        VStack(alignment: .leading, spacing: 8) {
          Text(
            "Wishbone sends crash and fault reports to its developer, with the versions of the app and of Wishbone, the device model, and the iOS version.",
            bundle: #bundle)
          Text(
            "It never sends anything from your family's lists, names, birthdays, or the address of your Wishbone.",
            bundle: #bundle)
          Text("This setting is for this device, whoever signs in.", bundle: #bundle)
        }
        .foregroundStyle(.primary)
      }
      if let privacyPolicy = Self.privacyPolicy {
        Section {
          WebLinkRow(title: String(localized: "Privacy policy", bundle: #bundle), destination: privacyPolicy)
        }
      }
    }
  }

  /// The switch. Without the app's diagnostics, as in a preview, it shows on and changes nothing.
  private var isOn: Binding<Bool> {
    Binding {
      diagnostics?.isOn ?? true
    } set: { isOn in
      diagnostics?.isOn = isOn
    }
  }
}
