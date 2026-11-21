import SwiftUI
import WishboneSession

/// Settings: what is about the user and this device, as a sheet from the user's avatar. See
/// `docs/screens/settings.md`.
///
/// It holds the Signed in block and Share diagnostics. Every other row joins with its own screen.
struct SettingsSheet: View {
  @Environment(Device.self) private var device
  @Environment(\.dismiss) private var dismiss

  let session: SessionModel

  /// Whether the warning before Sign out shows.
  @State private var isConfirmingSignOut = false

  var body: some View {
    NavigationStack {
      List {
        signedIn
        Section {
          NavigationLink {
            ShareDiagnosticsScreen(place: .pushed)
          } label: {
            Text("Share diagnostics", bundle: #bundle)
          }
        }
      }
      .navigationTitle(Text("Settings", bundle: #bundle))
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
    .alert(Text("Sign out?", bundle: #bundle), isPresented: $isConfirmingSignOut) {
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

  /// The Signed in block: the user's name, the instance address with its scheme, and Sign out.
  private var signedIn: some View {
    Section {
      VStack(alignment: .leading, spacing: 4) {
        if let name = session.user?.name {
          Text("Signed in as \(name)", bundle: #bundle)
        }
        // The full address, with its scheme, so a person can tell an `http` instance from an `https` one.
        // The primary color: the system's secondary gray is below 4.5:1 on the row.
        Text(session.session.instance.text)
          .textSelection(.enabled)
      }
      .accessibilityElement(children: .combine)

      // The row opens the warning, whose Sign out button has the destructive role. The row has no role of its own,
      // because a destructive row draws its words in the system's red, which is below 4.5:1 on the row as text.
      Button {
        isConfirmingSignOut = true
      } label: {
        Text("Sign out", bundle: #bundle)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .trailing) {
        if device.isSigningOut { ProgressView() }
      }
      .disabled(device.isSigningOut)
    }
  }
}

/// The user's avatar, at the top trailing corner of Home, Lists, and Gifts. It opens Settings. It shows the
/// initials of the user's name, until the person colors and the photos come.
struct AvatarButton: View {
  let session: SessionModel
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      AvatarInitials(name: session.user?.name ?? "")
    }
    .accessibilityLabel(Text("Settings", bundle: #bundle))
  }
}

/// A round mark with the initials of a name: the first letter of its first two words. An empty name shows a
/// person's outline.
private struct AvatarInitials: View {
  let name: String

  @ScaledMetric(relativeTo: .body) private var size: CGFloat = 30

  private var initials: String {
    String(name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first)).uppercased()
  }

  var body: some View {
    Group {
      if initials.isEmpty {
        Image(systemName: "person.crop.circle")
          .resizable()
          .scaledToFit()
      } else {
        Text(initials)
          .font(.footnote.weight(.semibold))
          .minimumScaleFactor(0.5)
          .lineLimit(1)
          .padding(4)
          .frame(width: size, height: size)
          .overlay(Circle().strokeBorder(.secondary, lineWidth: 1))
      }
    }
    .frame(width: size, height: size)
    .foregroundStyle(.primary)
  }
}
