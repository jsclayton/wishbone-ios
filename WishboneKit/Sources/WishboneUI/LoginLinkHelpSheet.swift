import SwiftUI

/// The help sheet of the signed-out screen: the four ways to get a login link. See "The help sheet" in
/// `docs/screens/signed-out.md`.
///
/// **Provisional.** A system list with one row for each case.
struct LoginLinkHelpSheet: View {
  @Environment(\.dismiss) private var dismiss

  /// The server project's page on running an instance.
  static let runningYourOwn = URL(string: "https://github.com/jsclayton/wishbone#deploy")

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text("Someone in your family runs Wishbone. Ask them, or your parent, for a login link.", bundle: #bundle)
          Text(
            "You use Wishbone in a browser. Open your sign-in screen there. It shows a QR code for you.",
            bundle: #bundle)
          Text(
            "You're signed in to the app on another device. Open Wishbone there, and use Sign in on another device.",
            bundle: #bundle)
        } header: {
          // The title is in the list, not the navigation bar, so that it wraps at any text size and in any language.
          Text("Getting a login link", bundle: #bundle)
            .font(.title2)
            .bold()
            .foregroundStyle(.primary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
        }
        Section {
          Text("Nobody in your family runs Wishbone yet.", bundle: #bundle)
          if let runningYourOwn = Self.runningYourOwn {
            WebLinkRow(
              title: String(localized: "Running your own Wishbone", bundle: #bundle), destination: runningYourOwn)
          }
        }
      }
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        // The sheet closes by a button too, not by the swipe alone. The system gives the button its words.
        ToolbarItem(placement: .cancellationAction) {
          Button(role: .close) { dismiss() }
        }
      }
    }
  }
}
