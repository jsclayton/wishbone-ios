import SwiftUI
import WishboneAPI
import WishboneSession

/// A version block: it says who must update what, when the app and the instance can't work together. It replaces
/// the whole window. See `docs/screens/version-block.md`.
///
/// Signed in, it has Sign out, so nobody is held on it. During sign-in, it shows over the signed-out screen with
/// Back, and the login link is not used.
struct VersionBlockScreen: View {
  /// What a block can do besides its own button.
  enum Way {
    /// Signed in: Try again runs the version check, and Sign out shows its warning first.
    case signedIn(SessionModel)
    /// During sign-in: Back returns to the signed-out screen.
    case signingIn
  }

  let block: VersionBlock
  let address: InstanceAddress
  let way: Way

  @Environment(Device.self) private var device
  @Environment(\.openURL) private var openURL

  @State private var isConfirmingSignOut = false
  @State private var isChecking = false

  /// Whether VoiceOver is on the title and the message.
  @AccessibilityFocusState private var isRead: Bool

  var body: some View {
    GeometryReader { window in
      ScrollView {
        VStack(spacing: 16) {
          ContentUnavailableView {
            Label {
              title
            } icon: {
              Image(systemName: icon)
            }
          } description: {
            message
          }
          .fixedSize(horizontal: false, vertical: true)
          // The title and the message are one element. VoiceOver goes to it when the block appears, and so reads it.
          .accessibilityElement(children: .combine)
          .accessibilityFocused($isRead)

          // **Provisional.** Plain default: the buttons under the message.
          VStack(spacing: 12) {
            actions
          }
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: window.size.height)
      }
    }
    .task { isRead = true }
    .signOutConfirmation(isPresented: $isConfirmingSignOut)
  }

  /// **Provisional.** The drafts of the titles.
  private var title: Text {
    switch block {
    case .appTooOld: Text("Update Wishbone", bundle: #bundle)
    case .instanceTooOld: Text("This Wishbone needs an update", bundle: #bundle)
    }
  }

  private var icon: String {
    switch block {
    case .appTooOld: "arrow.down.app"
    case .instanceTooOld: "server.rack"
    }
  }

  private var message: Text {
    switch block {
    case .appTooOld:
      Text("This version of Wishbone is too old for \(address.text). Update the app.", bundle: #bundle)
    case .instanceTooOld(let version, let minimum):
      Text(
        "\(address.text) runs Wishbone \(version). The app needs \(minimum) or later. Ask whoever runs it to update.",
        bundle: #bundle)
    }
  }

  @ViewBuilder private var actions: some View {
    switch block {
    case .appTooOld:
      Button {
        if let page = AppStorePage.url { openURL(page) }
      } label: {
        Text("Update Wishbone", bundle: #bundle)
      }
      .buttonStyle(.borderedProminent)
    case .instanceTooOld:
      if case .signedIn(let session) = way {
        Button {
          Task {
            isChecking = true
            await session.tryVersionCheckAgain()
            isChecking = false
          }
        } label: {
          Text("Try again", bundle: #bundle)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isChecking)
      }
    }
    switch way {
    case .signedIn:
      Button {
        isConfirmingSignOut = true
      } label: {
        Text("Sign out", bundle: #bundle)
      }
      .disabled(device.isSigningOut)
    case .signingIn:
      Button {
        device.cancelSignIn()
      } label: {
        Text("Back", bundle: #bundle)
      }
    }
  }
}
