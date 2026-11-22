import SwiftUI
import WishboneAPI
import WishboneSession

/// A user's page: the header, the line for a special case, good to know, the items of the user's primary list, and
/// Other lists. The user's own page is this same page, with no claim state. See `docs/screens/user.md`.
///
/// Claim state shows only as the server sends it, and the page never says who claimed. The Add item row, an item's
/// page, and the For {name} part come later.
///
/// **Provisional.** Plain default: a system list. The header is the avatar in the person's color with the name
/// under it, each part is a section, and the items are rows with the image at the leading edge.
struct UserPageScreen: View {
  let page: UserPage
  let session: SessionModel

  var body: some View {
    List {
      Section {
        Header(page: page)
        if let notice = page.notice {
          NoticeLine(notice: notice, name: page.user.name)
        }
      }
      if let goodToKnow = page.record.goodToKnow, !goodToKnow.allSatisfy(\.isWhitespace) {
        Section {
          MarkdownView(goodToKnow)
        } header: {
          Text("Good to know", bundle: #bundle)
        }
      }
      if let list = page.primaryList {
        Section {
          if page.seesClaimsAsParent {
            Text("You see what's been claimed here. Fully claimed items don't show.", bundle: #bundle)
              .foregroundStyle(.secondary)
          }
          if page.items.isEmpty {
            noItems(on: list)
          }
          ForEach(page.items) { item in
            ItemRowView(item: item, tileUserID: list.recipientIDs.first ?? page.user.id)
          }
        }
      }
      if !page.otherLists.isEmpty {
        Section {
          ForEach(page.otherLists) { list in
            NavigationLink(value: Page.list(id: list.id)) {
              OtherListRow(list: list)
            }
          }
        } header: {
          Text("Other lists", bundle: #bundle)
        }
      }
    }
    .cantReachLine(of: session)
    .navigationTitle(Text(page.user.name))
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }

  /// The items part with no items. For a viewer who can edit the list, it points to Add item.
  @ViewBuilder private func noItems(on list: ListRow) -> some View {
    Group {
      if list.canEdit {
        Text("Nothing here yet. Tap Add item to start the list.", bundle: #bundle)
      } else {
        Text("\(page.user.name) hasn't added anything yet.", bundle: #bundle)
      }
    }
    .foregroundStyle(.secondary)
  }
}

/// The header: the avatar, the name with the last name, "Deactivated" when it applies, and the birthday. VoiceOver
/// reads it as one element, and skips the avatar.
private struct Header: View {
  let page: UserPage

  var body: some View {
    VStack(spacing: 8) {
      PersonAvatar(user: page.user)
      VStack(spacing: 2) {
        Text(fullName)
          .font(.title2.weight(.bold))
        if page.user.isDeactivated {
          Text("Deactivated", bundle: #bundle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        birthday
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }

  /// The name with the last name, as the locale writes a full name.
  private var fullName: String {
    page.user.fullName
  }

  /// "Birthday: March 4", or "Turns 9 on March 4" when the birthday has a year.
  private var birthday: Text {
    let day = BirthdayWords.monthAndDay(page.birthday.month, page.birthday.day)
    if let turning = page.birthday.turning {
      return Text("Turns \(turning) on \(day)", bundle: #bundle)
    }
    return Text("Birthday: \(day)", bundle: #bundle)
  }
}

/// A birthday's month and day, in the device's locale: "March 4".
enum BirthdayWords {
  static func monthAndDay(_ month: Int, _ day: Int) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    // A leap year, so February 29 has a date.
    let date = calendar.date(from: DateComponents(year: 2000, month: month, day: day)) ?? .distantPast
    var style = Date.FormatStyle.dateTime.month(.wide).day()
    style.timeZone = .gmt
    return date.formatted(style)
  }
}

/// The line for a special case, under the header.
private struct NoticeLine: View {
  let notice: UserPage.Notice
  let name: String

  var body: some View {
    Group {
      switch notice {
      case .deactivatedChild:
        Text(
          "Only the admin can reactivate \(name). Until then, you can't change anything for \(name).", bundle: #bundle)
      case .adminAccess:
        Text(
          "You see \(name) because you're the admin. Their lists show only to people who share a group with them.",
          bundle: #bundle)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// An item's row, on a user's page and on a list's page: the image's place, the title, the price, and, for a giver,
/// how many are still wanted and "You claimed {n}". It is one element. At the largest text sizes, the image sits
/// above the text.
struct ItemRowView: View {
  let item: UserPage.Item

  /// The user whose color the tile takes: the list's first recipient.
  let tileUserID: String

  @Environment(\.dynamicTypeSize) private var size

  var body: some View {
    let layout =
      size.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
    layout {
      ItemTile(image: item.row.primaryImage, userID: tileUserID)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.row.title)
          .font(.body.weight(.semibold))
        if let price = PriceWords.row(
          priceMinor: item.row.priceMinor, topPriceMinor: item.row.topPriceMinor, currency: item.row.currency)
        {
          Text(price)
            .foregroundStyle(.secondary)
        }
        if let claim = item.claim {
          ClaimLines(claim: claim)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }
}

/// An item's claim state, as the server sent it: "{n} of {m} still wanted" or "Always wanted", and "You claimed
/// {n}" when the session's user claimed any.
struct ClaimLines: View {
  let claim: UserPage.Claim

  var body: some View {
    if let stillWanted = claim.stillWanted {
      Text("\(stillWanted) of \(claim.quantity) still wanted", bundle: #bundle)
        .foregroundStyle(.secondary)
    } else {
      Text("Always wanted", bundle: #bundle)
        .foregroundStyle(.secondary)
    }
    if claim.youClaimed > 0 {
      Text("You claimed \(claim.youClaimed)", bundle: #bundle)
        .font(.body.weight(.semibold))
    }
  }
}

/// An item's image: its primary image as it is, from the session's image cache, or else a soft tile in the
/// recipient's person color, with a colored symbol. It is decoration in a row whose title sits beside it, so
/// VoiceOver skips it. See "A color for each person" and "Images" in `docs/spec.md`.
///
/// **Provisional.** Plain default: the image filling a rounded square, or a soft tinted tile with a colored symbol.
private struct ItemTile: View {
  let image: ImageSummary?
  let userID: String

  @ScaledMetric(relativeTo: .body) private var scaled: CGFloat = 56
  private var side: CGFloat { min(scaled, 112) }

  var body: some View {
    SessionImage(image: image) { tile }
      .frame(width: side, height: side)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .accessibilityHidden(true)
  }

  /// The tile, while there is no image.
  private var tile: some View {
    let color = PersonPalette.color(forUserID: userID)
    return RoundedRectangle(cornerRadius: 10, style: .continuous)
      .fill(color.opacity(0.15))
      .overlay {
        Image(systemName: "gift")
          .font(.system(size: side * 0.4))
          .foregroundStyle(color)
      }
  }
}

/// A row of Other lists: the list's name and how many items it has, as the server counts them.
private struct OtherListRow: View {
  let list: ListRow

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(list.name)
      Text("\(list.itemCount) items", bundle: #bundle)
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .combine)
  }
}
