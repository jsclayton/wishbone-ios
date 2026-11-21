import SwiftUI
import WishboneSession

extension View {
  /// The warning before Sign out, with its Sign out button. See "Sign out" in `docs/spec.md`. Settings and the
  /// profile gate both show it.
  func signOutConfirmation(isPresented: Binding<Bool>) -> some View {
    modifier(SignOutConfirmation(isPresented: isPresented))
  }
}

private struct SignOutConfirmation: ViewModifier {
  @Environment(Device.self) private var device
  @Binding var isPresented: Bool

  func body(content: Content) -> some View {
    content.alert(Text("Sign out?", bundle: #bundle), isPresented: $isPresented) {
      Button(role: .destructive) {
        Task { await device.signOut() }
      } label: {
        Text("Sign out", bundle: #bundle)
      }
      Button(role: .cancel) {
      } label: {
        Text("Cancel", bundle: #bundle)
      }
    } message: {
      Text("You need a new login link to sign in again.", bundle: #bundle)
    }
  }
}
