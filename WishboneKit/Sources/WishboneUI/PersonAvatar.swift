import SwiftUI
import WishboneSession

/// A user's initials avatar, in their person color: white initials on a soft gradient of the color. It never
/// stands alone: a name always sits beside it, so VoiceOver skips it and reads the name. See "A color for each
/// person" in `docs/spec.md`.
///
/// **Provisional.** Plain default: a soft gradient initials avatar. The photo comes with the user's page.
struct PersonAvatar: View {
  let user: UserRow

  /// The avatar grows with the text size, up to a size that leaves the name beside it its room.
  @ScaledMetric(relativeTo: .title3) private var scaled: CGFloat = 56
  private var size: CGFloat { min(scaled, 88) }

  var body: some View {
    let color = PersonPalette.color(forUserID: user.id)
    // A drawing, not a view of text: the initials are a picture of the name that sits beside them. As text, the
    // accessibility audit measured them against the corners of their frame, outside the circle.
    Canvas { context, canvas in
      let circle = Path(ellipseIn: CGRect(origin: .zero, size: canvas))
      // The lightest stop is the palette's color, so the initials have at least its contrast everywhere.
      context.fill(
        circle,
        with: .linearGradient(
          Gradient(colors: [color, color.mix(with: .black, by: 0.2)]), startPoint: .zero,
          endPoint: CGPoint(x: 0, y: canvas.height)))
      let text = context.resolve(Text(initials).font(.title3.weight(.semibold)).foregroundStyle(.white))
      let fits = text.measure(in: canvas)
      let scale = min(1, canvas.width * 0.75 / max(fits.width, 1))
      context.translateBy(x: canvas.width / 2, y: canvas.height / 2)
      context.scaleBy(x: scale, y: scale)
      context.draw(text, at: .zero)
    }
    .frame(width: size, height: size)
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

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(user.name)
        .fixedSize(horizontal: false, vertical: true)
      if user.isDeactivated {
        Text("Deactivated", bundle: #bundle)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
