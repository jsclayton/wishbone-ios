import SwiftUI
import WishboneSession

/// A user's initials avatar, in their person color: white initials on a soft gradient of the color. It never
/// stands alone: a name always sits beside it, so VoiceOver skips it and reads the name. See "A color for each
/// person" in `docs/spec.md`.
///
/// **Provisional.** Plain default: a soft gradient initials avatar. The photo comes with the user's page.
struct PersonAvatar: View {
  let user: UserRow

  /// The avatar grows with the text size.
  @ScaledMetric(relativeTo: .title3) private var size: CGFloat = 56

  var body: some View {
    let color = PersonPalette.color(forUserID: user.id)
    Text(initials)
      .font(.title3.weight(.semibold))
      .foregroundStyle(.white)
      .lineLimit(1)
      .minimumScaleFactor(0.5)
      .padding(4)
      .frame(width: size, height: size)
      // The lightest stop is the palette's color, so the initials have at least its contrast everywhere.
      .background(
        Circle().fill(
          LinearGradient(
            colors: [color, color.mix(with: .black, by: 0.2)], startPoint: .top, endPoint: .bottom))
      )
      .accessibilityHidden(true)
  }

  /// The user's initials, as the locale abbreviates a name: from the name, and the last name when the session's
  /// user gets it.
  private var initials: String {
    var name = PersonNameComponents()
    name.givenName = user.name
    name.familyName = user.record?.lastName
    return name.formatted(.name(style: .abbreviated))
  }
}

/// A user's words beside their avatar: the name, never cut short, and "Deactivated" when the session's user gets
/// it.
struct PersonName: View {
  let user: UserRow
  var alignment = HorizontalAlignment.leading

  var body: some View {
    VStack(alignment: alignment, spacing: 2) {
      Text(user.name)
        .fixedSize(horizontal: false, vertical: true)
      if user.isDeactivated {
        Text("Deactivated", bundle: #bundle)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .multilineTextAlignment(alignment == .center ? .center : .leading)
  }
}
