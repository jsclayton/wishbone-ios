import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// Home's occasions: the countdown and Coming up. They are pure: the occasions, the people, the user's open gifts,
/// and the day go in. See "Home" in `docs/spec.md`, and `docs/screens/home.md`.
@Suite("Home's countdown and Coming up", .timeLimit(.minutes(1)))
struct HomeOccasionsTests {
  /// The device's zone.
  static let zone = TimeZone(identifier: "America/New_York")!

  /// The session's user.
  static let me = "7"

  /// Robin is the user, Emma is a child whose birthday has a year, and Sam's has none.
  static let people: [String: HomeOccasions.Person] = [
    me: HomeOccasions.Person(name: "Robin", birthYear: 1990, primaryListID: "70"),
    "12": HomeOccasions.Person(name: "Emma", birthYear: 2017, primaryListID: "120"),
    "13": HomeOccasions.Person(name: "Sam", primaryListID: "130"),
  ]

  /// The time in the device's zone.
  static func time(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  /// 1 March 2026, at 8:00 in the device's zone.
  static let now = time(2026, 3, 1, 8)

  static func occasion(
    _ id: String, _ kind: OccasionKind = .birthday, name: String = "Birthday", user: String? = "12",
    everyone: Bool = false, on date: String?
  ) -> HomeOccasions.Occasion {
    HomeOccasions.Occasion(
      id: id, kind: kind, name: name, userID: kind == .shared ? nil : user, isEveryone: everyone, nextDate: date)
  }

  static func home(
    _ occasions: [HomeOccasions.Occasion], gifts: [HomeOccasions.Gift] = [], today: Date = now
  ) -> HomeOccasions {
    HomeOccasions(occasions: occasions, people: people, me: me, gifts: gifts, today: today, timeZone: zone)
  }

  // MARK: - 1. The next occasion that is not the user's own

  @Test("The countdown is the soonest occasion in 60 days that is not the user's own birthday or custom occasion")
  func soonestNotOwn() {
    let home = Self.home([
      Self.occasion("1", user: Self.me, on: "2026-03-02"),
      Self.occasion("2", .custom, name: "Graduation", user: Self.me, on: "2026-03-03"),
      Self.occasion("3", on: "2026-03-10"),
      Self.occasion("4", .shared, name: "Holiday", everyone: true, on: "2026-03-05"),
      // 61 days away, past the window.
      Self.occasion("5", user: "13", on: "2026-05-01"),
    ])
    #expect(home.countdown.map(\.id) == ["4"])
    #expect(home.countdown.first?.whose == .shared(isEveryone: true))
    #expect(home.countdown.first?.daysLeft == 4)

    // With the shared occasion gone, the child's birthday is next.
    let later = Self.home([
      Self.occasion("1", user: Self.me, on: "2026-03-02"),
      Self.occasion("3", on: "2026-03-10"),
      Self.occasion("5", user: "13", on: "2026-04-30"),
    ])
    #expect(later.countdown.map(\.id) == ["3"])
    #expect(later.countdown.first?.whose == .person(id: "12", name: "Emma"))
  }

  @Test("An occasion 60 days away counts, and one past its date, or of a person not in the copy, doesn't")
  func window() {
    let home = Self.home([
      Self.occasion("1", on: "2026-02-28"),
      Self.occasion("2", user: "99", on: "2026-03-02"),
      Self.occasion("3", user: "13", on: "2026-04-30"),
      Self.occasion("4", .unknown("anniversary"), on: "2026-03-02"),
      Self.occasion("5", on: nil),
    ])
    #expect(home.comingUp.map(\.id) == ["3"])
    #expect(home.comingUp.first?.daysLeft == 60)
  }

  // MARK: - 2. Two on one day

  @Test("Two occasions on one day both show, each with its own counts")
  func twoOnOneDay() {
    let home = Self.home(
      [
        Self.occasion("3", on: "2026-03-10"),
        Self.occasion("4", .shared, name: "Reunion", on: "2026-03-10"),
        Self.occasion("5", user: "13", on: "2026-03-11"),
      ],
      gifts: [
        HomeOccasions.Gift(occasionID: "3", occasionDate: "2026-03-10", isBought: false),
        HomeOccasions.Gift(occasionID: "4", occasionDate: "2026-03-10", isBought: true),
        HomeOccasions.Gift(occasionID: "4", occasionDate: "2026-03-10", isBought: false),
      ])
    #expect(home.countdown.map(\.id) == ["3", "4"])
    #expect(
      home.countdown.map(\.gifts) == [
        HomeOccasion.Gifts(fromYou: 1, toBuy: 1), HomeOccasion.Gifts(fromYou: 2, toBuy: 1),
      ])
    #expect(home.countdown.last?.whose == .shared(isEveryone: false))
  }

  // MARK: - 3. The counts

  @Test("The counts are the user's open gifts for that occasion on its date, and how many are not bought")
  func counts() {
    let gifts = [
      HomeOccasions.Gift(occasionID: "3", occasionDate: "2026-03-10", isBought: true),
      HomeOccasions.Gift(occasionID: "3", occasionDate: "2026-03-10", isBought: false),
      HomeOccasions.Gift(occasionID: "3", occasionDate: "2026-03-10", isBought: true),
      // Another occasion, last year's date, and one whose occasion the giver can't see.
      HomeOccasions.Gift(occasionID: "5", occasionDate: "2026-03-10", isBought: false),
      HomeOccasions.Gift(occasionID: "3", occasionDate: "2025-03-10", isBought: false),
      HomeOccasions.Gift(occasionID: nil, occasionDate: "2026-03-10", isBought: false),
    ]
    let home = Self.home([Self.occasion("3", on: "2026-03-10")], gifts: gifts)
    #expect(home.countdown.first?.gifts == HomeOccasion.Gifts(fromYou: 3, toBuy: 1))

    // With none, the counts are zero: "Nothing from you yet".
    let none = Self.home([Self.occasion("3", on: "2026-03-10")])
    #expect(none.countdown.first?.gifts == HomeOccasion.Gifts(fromYou: 0, toBuy: 0))
  }

  // MARK: - 4. The age

  @Test("A birthday with a year gives the age on its date, and one with none, or a custom occasion, gives none")
  func age() {
    let home = Self.home([
      Self.occasion("3", on: "2026-03-10"),
      Self.occasion("4", user: "13", on: "2026-03-11"),
      Self.occasion("5", .custom, name: "Graduation", on: "2026-03-12"),
      Self.occasion("6", user: Self.me, on: "2027-01-02"),
    ])
    #expect(home.comingUp.map(\.turning) == [9, nil, nil])

    // In the next calendar year, the age counts that year.
    let winter = Self.home([Self.occasion("3", on: "2027-01-02")], today: Self.time(2026, 12, 20))
    #expect(winter.countdown.first?.turning == 10)
  }

  // MARK: - 5. Nothing in 60 days

  @Test("With nothing in 60 days, the countdown and Coming up are both empty")
  func nothing() {
    let home = Self.home([Self.occasion("3", on: "2026-06-10")])
    #expect(home.countdown.isEmpty)
    #expect(home.comingUp.isEmpty)

    // Only the user's own occasion: the countdown is empty, and Coming up has it.
    let own = Self.home([Self.occasion("1", user: Self.me, on: "2026-03-10")])
    #expect(own.countdown.isEmpty)
    #expect(own.comingUp.map(\.id) == ["1"])
  }

  // MARK: - 6. Coming up

  @Test("Coming up has the user's own occasions, soonest first, and a shared occasion once")
  func comingUp() {
    let home = Self.home([
      Self.occasion("3", on: "2026-03-20"),
      Self.occasion("4", .shared, name: "Holiday", everyone: true, on: "2026-03-05"),
      Self.occasion("1", user: Self.me, on: "2026-03-02"),
      Self.occasion("2", .custom, name: "Graduation", user: Self.me, on: "2026-03-20"),
      Self.occasion("5", user: "13", on: "2026-03-03"),
    ])
    #expect(home.comingUp.map(\.id) == ["1", "5", "4", "3", "2"])
    #expect(home.comingUp.filter { $0.id == "4" }.count == 1)
    #expect(home.comingUp.first?.whose == .own)
  }

  // MARK: - 7. Today, tomorrow, and in n days

  @Test("\"today\", \"tomorrow\" and \"in {n} days\" change at the device's midnight")
  func midnight() {
    let occasions = [Self.occasion("3", on: "2026-03-10")]
    let before = Self.home(occasions, today: Self.time(2026, 3, 8, 23, 59))
    let after = Self.home(occasions, today: Self.time(2026, 3, 9, 0, 0))
    let day = Self.home(occasions, today: Self.time(2026, 3, 10, 0, 0))
    #expect(before.countdown.first?.timeLeft == .days(2))
    #expect(after.countdown.first?.timeLeft == .tomorrow)
    #expect(day.countdown.first?.timeLeft == .today)

    // Daylight saving time starts on 8 March 2026 in the device's zone: a day of 23 hours is still one day.
    let spring = Self.home(occasions, today: Self.time(2026, 3, 7, 12))
    #expect(spring.countdown.first?.timeLeft == .days(3))

    // Midnight is the device's: at 23:30 in New York it is already the next day in UTC.
    let utc = HomeOccasions(
      occasions: occasions, people: Self.people, me: Self.me, gifts: [], today: Self.time(2026, 3, 8, 23, 30),
      timeZone: .gmt)
    #expect(utc.countdown.first?.timeLeft == .tomorrow)
  }

  // MARK: - 8. What a tap opens

  @Test("A person's occasion opens their page, the user's own opens their primary list, and a shared one nothing yet")
  func destination() {
    let home = Self.home([
      Self.occasion("1", user: Self.me, on: "2026-03-02"),
      Self.occasion("2", .custom, name: "Graduation", user: Self.me, on: "2026-03-03"),
      Self.occasion("3", on: "2026-03-04"),
      Self.occasion("5", .custom, name: "Recital", user: "13", on: "2026-03-05"),
      Self.occasion("4", .shared, name: "Holiday", on: "2026-03-06"),
    ])
    #expect(
      home.comingUp.map(\.destination) == [
        .list(id: "70"), .list(id: "70"), .user(id: "12"), .user(id: "13"), nil,
      ])

    // While the copy has no primary list for the user, their own occasion opens nothing.
    let noList = HomeOccasions(
      occasions: [Self.occasion("1", user: Self.me, on: "2026-03-02")],
      people: [Self.me: HomeOccasions.Person(name: "Robin")], me: Self.me, gifts: [], today: Self.now,
      timeZone: Self.zone)
    #expect(noList.comingUp.first?.destination == nil)
  }
}

/// Home's occasions, as the session model reads them from a copy that a real server filled.
@Suite("Home's occasions from the copy", .timeLimit(.minutes(1)))
@MainActor
struct HomeOccasionsCopyTests {
  @Test("The session model's countdown and Coming up come from the copy, with the giver's own counts")
  func fromTheCopy() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    // Emma's birthday is in 10 days, so it is in the window whatever the zone. The giver's own is far away.
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = .gmt
    let soon = try #require(utc.date(byAdding: .day, value: 10, to: .now))
    let far = try #require(utc.date(byAdding: .day, value: 180, to: .now))
    let day = utc.dateComponents([.month, .day], from: soon)
    let farDay = utc.dateComponents([.month, .day], from: far)
    let giver = try await builder.person(
      "Robin", birthday: (try #require(farDay.month), try #require(farDay.day)))
    let emma = try await builder.person(
      "Emma", birthday: (try #require(day.month), try #require(day.day)), birthYear: 2017)
    _ = try await builder.group("Cousins", users: [giver, emma])
    let list = try await builder.primaryList(of: emma)
    let kite = try await builder.item("Kite", on: list, as: emma)
    let puzzle = try await builder.item("Puzzle", on: list, as: emma)
    let birthday = try await builder.birthday(of: emma, as: giver)
    _ = try await builder.claim(kite, as: giver, for: birthday)
    _ = try await builder.claim(puzzle, as: giver, for: birthday, isBought: true)

    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: giver))
    let session = try #require(device.session)
    // The sign-in can end before the session publishes its last write, so the test waits for the rows it reads:
    // Emma's birthday, and both of the giver's gifts. `untilInStep` leaves out the occasions, which other tests on
    // the shared server change.
    let birthdayID = birthday.id
    await until {
      session.occasions.contains { $0.id == birthdayID } && session.giving.count == 2
        && session.user(id: emma.id) != nil
    }
    let home = session.homeOccasions()

    // On a shared server, other tests' occasions for everyone can come first, so the test finds Emma's.
    let row = try #require(home.comingUp.first { $0.id == birthday.id })
    #expect(row.whose == .person(id: emma.id, name: emma.name))
    #expect((9...11).contains(row.daysLeft))
    #expect(row.gifts == HomeOccasion.Gifts(fromYou: 2, toBuy: 1))
    #expect(row.destination == .user(id: emma.id))
    #expect(row.turning != nil)
    // The giver's own birthday is past the window, and never in the countdown.
    #expect(!home.countdown.contains { $0.whose == .own })
  }
}
