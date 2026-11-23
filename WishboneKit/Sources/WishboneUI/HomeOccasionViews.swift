import SwiftUI
import WishboneSession

// Home's countdown and Coming up. What they hold is in `HomeOccasions`, in the session module. See
// `docs/screens/home.md`.

/// One occasion of the countdown: its words, the time left, and the user's own gift counts. The card's color is the
/// occasion's person's, and the white words sit on it.
///
/// It is one element: the occasion, the time left, then the gift counts. At the largest text sizes, its lines stack.
///
/// **Provisional.** Plain default: a gradient card in the occasion's person color, as a list row.
struct CountdownOccasion: View {
  let occasion: HomeOccasion

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    let layout =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
      : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
    VStack(alignment: .leading, spacing: 8) {
      layout {
        VStack(alignment: .leading, spacing: 2) {
          OccasionWords(occasion: occasion)
            .font(.title3.weight(.bold))
          switch occasion.whose {
          case .shared(isEveryone: true):
            Text("Everyone", bundle: #bundle)
              .font(.subheadline)
          case .person(_, let name):
            if let turning = occasion.turning {
              Text("\(name) turns \(turning)", bundle: #bundle)
                .font(.subheadline)
            }
          case .shared, .own:
            EmptyView()
          }
        }
        if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
        TimeLeftWords(timeLeft: occasion.timeLeft)
          .font(.headline)
      }
      GiftCountWords(gifts: occasion.gifts)
        .font(.subheadline)
    }
    .foregroundStyle(.white)
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 8)
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
  }

  /// The card's color: the occasion's person's, and a fixed one of the palette for a shared occasion.
  static func background(of occasion: HomeOccasion) -> some View {
    let color =
      switch occasion.whose {
      case .person(let id, _): PersonPalette.color(forUserID: id)
      case .shared, .own: PersonPalette.color(of: .indigo)
      }
    // The lightest stop is the palette's color, so the white words have at least its contrast everywhere.
    return LinearGradient(
      colors: [color, color.mix(with: .black, by: 0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
  }
}

/// One row of Coming up: the person's avatar, the occasion's words, and the time left. It is one element: the
/// occasion, the person, the time left. On the Occasions screen, the date shows before the time left.
struct ComingUpRow: View {
  let occasion: HomeOccasion
  let session: SessionModel

  /// Whether the row shows the occasion's date: on the Occasions screen, not on Home.
  var showsDate = false

  var body: some View {
    HStack(spacing: 12) {
      avatar
      VStack(alignment: .leading, spacing: 2) {
        OccasionWords(occasion: occasion)
        if showsDate {
          Text(OccasionDateWords.monthAndDay(occasion.date))
            .font(.subheadline)
        }
        TimeLeftWords(timeLeft: occasion.timeLeft)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  /// The person's avatar, or a symbol for a shared occasion. VoiceOver skips it.
  @ViewBuilder private var avatar: some View {
    let user: UserRow? =
      switch occasion.whose {
      case .person(let id, _): session.user(id: id)
      case .own: session.user
      case .shared: nil
      }
    if let user {
      PersonAvatar(user: user, size: .small)
    } else {
      SharedOccasionSymbol()
    }
  }
}

/// The symbol in place of an avatar for a shared occasion, the size of a small avatar.
struct SharedOccasionSymbol: View {
  @ScaledMetric(relativeTo: .body) private var scaled: CGFloat = 28

  var body: some View {
    let size = min(scaled, 56)
    Image(systemName: "calendar")
      .font(.system(size: size * 0.5))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(PersonPalette.color(of: .indigo), in: .circle)
      .accessibilityHidden(true)
  }
}

/// The occasion's words: "Emma's birthday", "Emma's Recital", "Holiday", "Your birthday".
struct OccasionWords: View {
  let occasion: HomeOccasion

  var body: some View {
    switch (occasion.whose, occasion.kind) {
    case (.person(_, let name), .birthday):
      Text("\(name)'s birthday", bundle: #bundle)
    case (.person(_, let name), _):
      Text(
        "\(name)'s \(occasion.name)", bundle: #bundle,
        comment: "The first is the person's name. The second is the name of their occasion, such as graduation.")
    case (.own, .birthday):
      Text("Your birthday", bundle: #bundle)
    case (.own, _):
      Text(
        "Your \(occasion.name)", bundle: #bundle, comment: "The name of the user's own occasion, such as graduation.")
    case (.shared, _):
      Text(occasion.name)
    }
  }
}

/// An occasion's date, in the device's locale: "December 25".
enum OccasionDateWords {
  /// The month and day of a `YYYY-MM-DD` date. Text that is not such a date shows as it is.
  static func monthAndDay(_ text: String) -> String {
    let parts = text.split { !$0.isNumber }.compactMap { Int($0) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    guard parts.count == 3,
      let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    else { return text }
    var style = Date.FormatStyle.dateTime.month(.wide).day()
    style.timeZone = .gmt
    return date.formatted(style)
  }
}

/// The time left: "today", "tomorrow", "in 12 days".
struct TimeLeftWords: View {
  let timeLeft: HomeOccasion.TimeLeft

  var body: some View {
    switch timeLeft {
    case .today: Text("today", bundle: #bundle)
    case .tomorrow: Text("tomorrow", bundle: #bundle)
    case .days(let days): Text("in \(days) days", bundle: #bundle)
    }
  }
}

/// The user's own gifts for the occasion: "2 from you · 1 still to buy", "2 from you", "Nothing from you yet".
struct GiftCountWords: View {
  let gifts: HomeOccasion.Gifts

  var body: some View {
    if gifts.fromYou == 0 {
      Text("Nothing from you yet", bundle: #bundle)
    } else if gifts.toBuy == 0 {
      Text("\(gifts.fromYou) from you", bundle: #bundle)
    } else {
      Text("\(gifts.fromYou) from you · \(gifts.toBuy) still to buy", bundle: #bundle)
    }
  }
}

/// A timeline that changes at each of the device's midnights, so "today", "tomorrow" and "in {n} days" move with
/// the day while Home shows.
struct MidnightSchedule: TimelineSchedule {
  func entries(from startDate: Date, mode: Mode) -> UnfoldFirstSequence<Date> {
    sequence(first: startDate) { date in
      Calendar.autoupdatingCurrent.nextDate(
        after: date, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime)
    }
  }
}

extension HomeOccasion.Destination {
  /// The page that an occasion opens. See "How each thing is reached" in `docs/spec.md`.
  var page: Page {
    switch self {
    case .user(let id): .user(id: id)
    case .list(let id): .list(id: id)
    case .sharedOccasion(let id): .sharedOccasion(id: id)
    }
  }
}
