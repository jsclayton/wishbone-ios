import SwiftUI
import WishboneSession

/// A part's heading: "Your children", "Your parents", or the group's name, with "through {group}" for a group that
/// the user is in by nesting. Home and the People page share it. It is plain text, not a
/// link, and a heading for the VoiceOver rotor.
struct PartHeading: View {
  let part: PeoplePart

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      switch part.kind {
      case .children:
        Text("Your children", bundle: #bundle)
      case .parents:
        Text("Your parents", bundle: #bundle)
      case .group(let group, let through):
        Text(group.name)
        if let through {
          Text("through \(through.name)", bundle: #bundle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
    }
    .font(.headline)
    .foregroundStyle(.primary)
    .textCase(nil)
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}
