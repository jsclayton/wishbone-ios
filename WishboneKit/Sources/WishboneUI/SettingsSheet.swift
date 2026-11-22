import SwiftUI
import WishboneSession

/// Settings: what is about the user and this device, as a sheet from the user's avatar. See
/// `docs/screens/settings.md`.
///
/// The sections are in the order of `SettingsSection`. A section that is not built yet joins there with its screen.
struct SettingsSheet: View {
  @Environment(Device.self) private var device
  @Environment(\.dismiss) private var dismiss

  let session: SessionModel

  /// Whether the warning before Sign out shows.
  @State private var isConfirmingSignOut = false

  var body: some View {
    NavigationStack {
      List {
        if session.isInstanceUnreachable {
          // The line blocks nothing: every row still opens. It keeps the default style, the primary color: the
          // system's secondary gray is below 4.5:1 on the row.
          Text("Can't reach \(session.session.instance.text)", bundle: #bundle)
        }
        ForEach(sections, id: \.self) { section in
          switch section {
          case .signedIn: signedIn
          case .signInAndDevices: signInAndDevices
          case .shareDiagnostics: shareDiagnostics
          case .forTheAdmin: forTheAdmin
          case .about: about
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
    .signOutConfirmation(isPresented: $isConfirmingSignOut)
  }

  /// The sections for the signed-in user. Before the user's record is in the copy, they are as for a user who is not
  /// the admin, and who has parents: the fewest.
  private var sections: [SettingsSection] {
    let record = session.user?.record
    return SettingsSection.shown(isAdmin: record?.isAdmin ?? false, hasParents: !(record?.parentIDs.isEmpty ?? false))
  }

  /// The section that holds Sign-in and devices, with the help line on Require Face ID as its footer. See "No Face
  /// ID lock of the app's own" in `docs/spec.md`.
  private var signInAndDevices: some View {
    Section {
    } footer: {
      // The label color itself: the system's secondary gray of a footer is below 4.5:1. The hierarchical `.primary`
      // of a section's footer is that gray.
      Text(
        "To keep your gifts private on a shared device, touch and hold Wishbone on the Home Screen and choose Require Face ID.",
        bundle: #bundle
      )
      .foregroundStyle(Color.primary)
    }
  }

  private var shareDiagnostics: some View {
    Section {
      NavigationLink {
        ShareDiagnosticsScreen(place: .pushed)
      } label: {
        Text("Share diagnostics", bundle: #bundle)
      }
    }
  }

  /// For the admin: Blocked stores, and the footer on the jobs that the person who runs Wishbone does on the server,
  /// with its link to the server's docs. Only the admin sees it. See "Blocked stores" in `docs/spec.md`.
  private var forTheAdmin: some View {
    Section {
      NavigationLink {
        BlockedStoresScreen(session: session)
      } label: {
        Text("Blocked stores", bundle: #bundle)
      }
    } header: {
      // The label color itself, as in the footers.
      Text("For the admin", bundle: #bundle)
        .foregroundStyle(Color.primary)
    } footer: {
      VStack(alignment: .leading, spacing: 8) {
        // The label color itself, as in the footer of Sign-in and devices.
        Text(
          "Moving the admin role, backups and server settings are done by the person who runs Wishbone, on the server.",
          bundle: #bundle
        )
        .foregroundStyle(Color.primary)
        if let docs = AppAbout.current.operatorDocs {
          WebLinkRow(title: String(localized: "Running Wishbone", bundle: #bundle), destination: docs)
            .frame(minHeight: 44)
        }
      }
    }
  }

  /// Source code, Acknowledgements, and the app's version and build.
  private var about: some View {
    let about = AppAbout.current
    return Section {
      if let sourceCode = about.sourceCode {
        WebLinkRow(title: String(localized: "Source code", bundle: #bundle), destination: sourceCode)
      }
      NavigationLink {
        AcknowledgementsScreen()
      } label: {
        Text("Acknowledgements", bundle: #bundle)
      }
      Text("Version \(about.version) (\(about.build))", bundle: #bundle)
        .textSelection(.enabled)
    } header: {
      // The label color itself, as in the footer above.
      Text("About", bundle: #bundle)
        .foregroundStyle(Color.primary)
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
