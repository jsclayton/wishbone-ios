import SwiftUI
import WishboneSession

/// The Home tab. For now it holds People: "Your children", then "Your parents", then one part for each of the
/// user's groups, each with its users as initials avatars. The countdown and Coming up come later. See
/// `docs/screens/home.md`.
///
/// Its states are the ones that every screen shares. "Nobody to see" is People's empty line, after a sync that
/// found nobody.
///
/// A person is one button, whose words are the ones that show: the name, then "Deactivated" when it applies. The
/// avatar beside it is a drawing that VoiceOver skips, and a tap on it opens the person too.
///
/// **Provisional.** Plain default: a system list. The "People" heading is a row that pushes the People page. Each
/// part is a section. Each person is a row, with the avatar and the name beside it, at every text size, and the rows
/// flow into as many columns as fit: one in a narrow window, more in a wide one.
struct HomeScreen: View {
  let session: SessionModel

  /// The pages pushed on Home. A tap on a person pushes their page.
  @Binding var pages: [Page]

  var body: some View {
    let people = session.people
    let state = session.screenState(hasRows: !people.isEmpty)
    List {
      // The heading shows over People, and over its empty line. While nothing is known, the state shows alone.
      if state != .loading && state != .cantReach {
        Section {
          NavigationLink(value: Page.people) {
            Text("People", bundle: #bundle)
              .font(.title2.weight(.bold))
          }
          .accessibilityAddTraits(.isHeader)
          if people.isEmpty {
            Text("Nobody is here yet. The admin adds people to your groups.", bundle: #bundle)
              .foregroundStyle(.secondary)
          }
        }
      }
      ForEach(people) { part in
        Section {
          Columns(minimum: 200) {
            ForEach(part.users) { user in
              HStack(spacing: 12) {
                avatar(of: user)
                name(of: user)
              }
            }
          }
          .padding(.vertical, 8)
        } header: {
          PartHeading(part: part)
        }
      }
    }
    .sharedStates(of: session, hasRows: !people.isEmpty) {
      // People's empty line is in the list, under its heading.
      EmptyView()
    }
    .navigationTitle(Text("Home", bundle: #bundle))
  }

  /// A person's avatar. A tap on it opens the person, as a tap on the name does. VoiceOver skips it, and reads the
  /// name's button.
  private func avatar(of user: UserRow) -> some View {
    PersonAvatar(user: user)
      .contentShape(.circle)
      .onTapGesture { open(user) }
  }

  /// A person's name, as the button that opens them. The button holds only words, so its element is the name, then
  /// "Deactivated" when it applies, and its text grows with the text size.
  private func name(of user: UserRow) -> some View {
    Button {
      open(user)
    } label: {
      PersonName(user: user)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
  }

  /// Pushes the user's page on Home.
  private func open(_ user: UserRow) {
    pages.append(.user(id: user.id))
  }
}

/// A part's heading: "Your children", "Your parents", or the group's name, with "through {group}" for a group that
/// the user is in by nesting.
private struct PartHeading: View {
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

/// Columns of one width, as many as fit, each at least `minimum` wide: the people of a part flow into them. It is
/// not lazy: a part is family-sized, and each change of the text size lays every person out again.
private struct Columns: Layout {
  var minimum: CGFloat = 88
  var spacing: CGFloat = 8

  private func columns(in width: CGFloat) -> (count: Int, width: CGFloat) {
    let count = max(1, Int((width + spacing) / (minimum + spacing)))
    return (count, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
  }

  /// The height of each row, from the tallest person in it.
  private func rowHeights(_ subviews: Subviews, count: Int, width: CGFloat) -> [CGFloat] {
    stride(from: 0, to: subviews.count, by: count).map { start in
      subviews[start..<min(start + count, subviews.count)]
        .map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        .max() ?? 0
    }
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    // A width that isn't finite, such as a stack's probe for how far a view can grow, is no width.
    let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? (minimum * 3 + spacing * 2)
    let (count, column) = columns(in: width)
    let heights = rowHeights(subviews, count: count, width: column)
    return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1)))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let (count, column) = columns(in: bounds.width)
    let heights = rowHeights(subviews, count: count, width: column)
    var y = bounds.minY
    for (row, height) in heights.enumerated() {
      for place in 0..<count {
        let index = row * count + place
        guard index < subviews.count else { break }
        let x = bounds.minX + CGFloat(place) * (column + spacing)
        subviews[index].place(
          at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: column, height: height))
      }
      y += height + spacing
    }
  }
}
