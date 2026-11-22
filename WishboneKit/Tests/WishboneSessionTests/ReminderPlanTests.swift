import Foundation
import Testing
import UserNotifications
import WishboneAPI
import WishboneSession

/// The reminder plan, which is pure: occasions, settings, and a clock go in, and the reminders come out. See "Staying
/// correct" and "One switch, and the timing" in `docs/spec.md`.
@Suite("The reminder plan", .timeLimit(.minutes(1)))
struct ReminderPlanTests {
  /// The device's zone. Daylight saving time starts on 8 March 2026, between a reminder and its occasion.
  static let zone = TimeZone(identifier: "America/New_York")!

  static let session = Session(
    instance: InstanceAddress("https://wishbone.example/family")!, token: "a-token", userID: "7")

  /// Emma, whose birthday and graduation the session's user sees.
  static let names = ["7": "Robin", "12": "Emma"]

  /// The time in the device's zone.
  static func time(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  /// 1 March 2026, at 8:00 in the device's zone.
  static let now = time(2026, 3, 1, 8)

  static func occasion(
    _ id: String, _ kind: OccasionKind = .birthday, name: String = "Birthday", user: String? = "12", on date: String?
  ) -> ReminderPlan.Occasion {
    ReminderPlan.Occasion(id: id, kind: kind, name: name, userID: kind == .shared ? nil : user, nextDate: date)
  }

  static func plan(
    _ occasions: [ReminderPlan.Occasion],
    settings: ReminderSettings = ReminderSettings(),
    now: Date = now
  ) -> [PlannedReminder] {
    ReminderPlan.reminders(
      for: occasions, names: names, session: session, settings: settings, now: now, timeZone: zone)
  }

  /// The fire time of a reminder, as the device's zone reads its trigger.
  static func fires(_ reminder: PlannedReminder) -> Date? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: reminder.fires)
  }

  static func components(_ year: Int, _ month: Int, _ day: Int) -> DateComponents {
    DateComponents(year: year, month: month, day: day, hour: 9, minute: 0)
  }

  // MARK: - 1. Two for each occasion, at 9:00

  @Test("Each occasion gives two reminders, at 9:00 in the device's zone: 2 weeks before, and on the day")
  func twoAtNine() {
    let reminders = Self.plan([Self.occasion("40", on: "2026-03-20")])

    #expect(reminders.map(\.identifier.kind) == [.early, .onTheDay])
    #expect(reminders.map(\.fires) == [Self.components(2026, 3, 6), Self.components(2026, 3, 20)])
    // Daylight saving time starts on 8 March, between the two: the early one is at 9:00 EST, and the one on the day at
    // 9:00 EDT. The trigger names no zone, so each fires at 9:00 in the zone that the device has then.
    #expect(reminders.map(Self.fires) == [Self.time(2026, 3, 6, 9), Self.time(2026, 3, 20, 9)])
    let offsets = reminders.compactMap(Self.fires).map { Self.zone.secondsFromGMT(for: $0) / 3600 }
    #expect(offsets == [-5, -4])
    #expect(reminders.allSatisfy { $0.fires.timeZone == nil && $0.fires.second == nil })
    #expect(reminders.map(\.phrase.early) == [.twoWeeks, nil])
  }

  @Test("The early reminder follows the setting, the one on the day has its own switch, and the main switch stops both")
  func settings() {
    let occasions = [Self.occasion("40", on: "2026-04-10")]

    let oneWeek = Self.plan(occasions, settings: ReminderSettings(early: .oneWeek))
    #expect(oneWeek.map(\.fires) == [Self.components(2026, 4, 3), Self.components(2026, 4, 10)])
    #expect(oneWeek.first?.phrase.early == .oneWeek)

    let fourWeeks = Self.plan(occasions, settings: ReminderSettings(early: .fourWeeks))
    #expect(fourWeeks.map(\.fires) == [Self.components(2026, 3, 13), Self.components(2026, 4, 10)])
    #expect(fourWeeks.first?.phrase.early == .fourWeeks)

    let noDay = Self.plan(occasions, settings: ReminderSettings(onTheDay: false))
    #expect(noDay.map(\.identifier.kind) == [.early])

    #expect(Self.plan(occasions, settings: ReminderSettings(isOn: false)).isEmpty)
  }

  @Test("The date is the occasion's next date, at 9:00 in the device's zone, whatever zone the device is in")
  func deviceZone() throws {
    let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
    let reminders = ReminderPlan.reminders(
      for: [Self.occasion("40", on: "2026-03-30")], names: Self.names, session: Self.session,
      settings: ReminderSettings(), now: Self.now, timeZone: tokyo)
    #expect(reminders.map(\.fires) == [Self.components(2026, 3, 16), Self.components(2026, 3, 30)])
  }

  // MARK: - 2. The next 60 days, and the 60 soonest

  @Test("Only occasions in the next 60 days, and only reminders whose time has not passed")
  func window() {
    let reminders = Self.plan([
      // Today, before 9:00: the one on the day. The early one has passed.
      Self.occasion("1", on: "2026-03-01"),
      // In 5 days: the early one has passed.
      Self.occasion("2", on: "2026-03-06"),
      // In 60 days: both.
      Self.occasion("3", on: "2026-04-30"),
      // In 61 days: none, though its early one would be in the window.
      Self.occasion("4", on: "2026-05-01"),
      // None left, and a date that can't be read.
      Self.occasion("5", on: nil),
      Self.occasion("6", on: "someday"),
    ])
    #expect(
      reminders.map(\.identifier.description) == [
        "reminder|day|1|7|https://wishbone.example/family",
        "reminder|day|2|7|https://wishbone.example/family",
        "reminder|early|3|7|https://wishbone.example/family",
        "reminder|day|3|7|https://wishbone.example/family",
      ])

    // After 9:00 on the day, the one on the day has passed too.
    let later = Self.plan([Self.occasion("1", on: "2026-03-01")], now: Self.time(2026, 3, 1, 9, 1))
    #expect(later.isEmpty)
  }

  @Test("At most the 60 soonest reminders, the soonest first")
  func soonest() {
    // 40 occasions, one each day from 15 March to 23 April: 80 reminders.
    let occasions = (0..<40).map { offset in
      Self.occasion("\(100 + offset)", on: Self.dateText(Self.time(2026, 3, 15 + offset)))
    }
    let every = occasions.flatMap { Self.plan([$0]) }
    #expect(every.count == 80)

    let reminders = Self.plan(occasions.reversed())
    #expect(ReminderPlan.limit == 60)
    #expect(reminders.count == 60)
    let times = reminders.compactMap(Self.fires)
    #expect(times == times.sorted())
    #expect(times == Array(every.compactMap(Self.fires).sorted().prefix(60)))
  }

  /// The date as `YYYY-MM-DD`, in the device's zone.
  static func dateText(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return [parts.year!, parts.month!, parts.day!].map { $0 < 10 ? "0\($0)" : "\($0)" }.joined(separator: "-")
  }

  // MARK: - 3. The identifiers, and no repeat

  @Test("Each identifier has the instance, the user, the occasion and the kind, and reads back. No trigger repeats")
  func identifiers() throws {
    let reminders = Self.plan([Self.occasion("40", on: "2026-03-30")])
    for reminder in reminders {
      let identifier = reminder.identifier
      #expect(identifier.instance == Self.session.instance)
      #expect(identifier.userID == "7")
      #expect(identifier.occasionID == "40")
      #expect(ReminderIdentifier(identifier.description) == identifier)

      let request = ReminderRequest(reminder, words: .none)
      #expect(request.identifier == identifier.description)
      #expect(!request.repeats)
      let trigger = try #require(request.notificationRequest.trigger as? UNCalendarNotificationTrigger)
      #expect(!trigger.repeats)
    }
    #expect(reminders.map(\.identifier.kind) == [.early, .onTheDay])

    // An instance address with a path and a port reads back whole. Other text is not an identifier.
    let odd = ReminderIdentifier(
      instance: try #require(InstanceAddress("http://10.0.0.5:8080/a|b")), userID: "7", occasionID: "40",
      kind: .early)
    #expect(ReminderIdentifier(odd.description) == odd)
    #expect(ReminderIdentifier("reminder|soon|40|7|https://wishbone.example") == nil)
    #expect(ReminderIdentifier("something|early|40|7|https://wishbone.example") == nil)
    #expect(ReminderIdentifier("reminder|early|40|7") == nil)
  }

  // MARK: - 4. The words

  @Test("The words name someone's birthday, a custom occasion, a shared occasion, and the user's own")
  func phrases() {
    let reminders = Self.plan([
      Self.occasion("1", on: "2026-03-20"),
      Self.occasion("2", .custom, name: "graduation", on: "2026-03-21"),
      Self.occasion("3", .shared, name: "Christmas", on: "2026-03-22"),
      Self.occasion("4", user: "7", on: "2026-03-23"),
      Self.occasion("5", .custom, name: "anniversary", user: "7", on: "2026-03-24"),
    ])
    let early = reminders.filter { $0.identifier.kind == .early }.map(\.phrase)
    let onTheDay = reminders.filter { $0.identifier.kind == .onTheDay }.map(\.phrase)
    let subjects: [ReminderSubject] = [
      .birthday(person: "Emma"),
      .custom(person: "Emma", occasion: "graduation"),
      .shared(occasion: "Christmas"),
      .ownBirthday,
      .ownCustom(occasion: "anniversary"),
    ]
    #expect(early == subjects.map { ReminderPhrase(subject: $0, early: .twoWeeks) })
    #expect(onTheDay == subjects.map { ReminderPhrase(subject: $0, early: nil) })
  }

  @Test("An occasion that the app can't name gets no reminder: a kind it doesn't know, or a person not in the copy")
  func unnamed() {
    let reminders = Self.plan([
      Self.occasion("1", .unknown("anniversary"), name: "Anniversary", on: "2026-03-20"),
      Self.occasion("2", user: "99", on: "2026-03-20"),
      Self.occasion("3", .custom, name: "graduation", user: "99", on: "2026-03-20"),
    ])
    #expect(reminders.isEmpty)
  }

  @Test("The request carries the words, from the words it is given")
  func words() {
    let words = ReminderWords(
      title: { "Title" },
      body: { phrase in phrase.early == nil ? "On the day" : "Early" })
    let requests = Self.plan([Self.occasion("40", on: "2026-03-30")]).map { ReminderRequest($0, words: words) }
    #expect(requests.map(\.title) == ["Title", "Title"])
    #expect(requests.map(\.body) == ["Early", "On the day"])
    #expect(requests.map(\.fires) == [Self.components(2026, 3, 16), Self.components(2026, 3, 30)])
  }
}
