import Foundation
import TestSupport
import Testing
import UserNotifications
import WishboneAPI
import WishboneSession

/// The secrecy suite: each system surface's payload, built from the synced copy, holds exactly the fields of its
/// allow list, and no value from the fixture's gifts. See "The secrecy suite" in `docs/development.md`, and "The rule
/// for system surfaces" in `docs/spec.md`.
///
/// The fixture user, Robin, is both a recipient (Casey claimed an item on Robin's list) and a giver (Robin has open
/// gifts, with notes and from labels, on Jordan's list, where Casey has one too). A new system surface joins the suite
/// when it is built.
@Suite("The secrecy suite", .timeLimit(.minutes(2)))
@MainActor
struct SecrecyTests {
  /// What the suite signs in with, and the values that no payload may hold.
  struct Seeded {
    let robin: Fixture.Person
    let jordan: Fixture.Person
    let graduation: Fixture.Occasion
    let recital: Fixture.Occasion
    let reunion: Fixture.Occasion

    /// The gifts' IDs, notes and from labels, the names of the givers on the claims, and the items' titles.
    let secrets: [String]
    let giftIDs: [String]
  }

  let instance: Instance
  var builder: FixtureBuilder { instance.builder }

  /// The suite has a server of its own, so no other test's occasion is in a payload.
  init() async throws {
    instance = try await Instance(server: try await TestServer.start())
  }

  /// The day that is `days` from today, in UTC: the zone of the device and of the users.
  static func day(in days: Int) -> (year: Int, month: Int, day: Int) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let parts = calendar.dateComponents(
      [.year, .month, .day], from: calendar.date(byAdding: .day, value: days, to: Date())!)
    return (parts.year!, parts.month!, parts.day!)
  }

  /// Seeds the fixture. Every occasion that Robin sees is in the next 60 days, but Robin's birthday and Casey's.
  private func fixture() async throws -> Seeded {
    let far = Self.day(in: 180)
    let robin = try await builder.person("Robin", birthday: (far.month, far.day))
    let soon = Self.day(in: 40)
    let jordan = try await builder.person("Jordan", birthday: (soon.month, soon.day))
    let casey = try await builder.person("Casey", birthday: (far.month, far.day))
    for person in [robin, jordan, casey] { try await builder.confirmProfile(of: person) }
    let family = try await builder.group("Family", users: [robin, jordan, casey])
    let reunionDay = Self.day(in: 30)
    let reunion = try await builder.sharedOccasion(
      "Reunion", month: reunionDay.month, day: reunionDay.day, groups: [family])
    let graduationDay = Self.day(in: 20)
    let graduation = try await builder.customOccasion(
      "Graduation", of: jordan, year: graduationDay.year, month: graduationDay.month, day: graduationDay.day)
    let recitalDay = Self.day(in: 25)
    let recital = try await builder.customOccasion(
      "Recital", of: robin, year: recitalDay.year, month: recitalDay.month, day: recitalDay.day)

    // Robin as a recipient: Casey claimed an item on Robin's list.
    let robinsList = try await builder.primaryList(of: robin)
    let bike = try await builder.item("Bike", on: robinsList, as: robin)
    let caseysForRobin = try await builder.claim(
      bike, as: casey, for: reunion, fromLabel: "Casey's label", note: "Casey's note for Robin")
    // Robin as a giver, with notes and from labels, on Jordan's list, where Casey gives too.
    let jordansList = try await builder.primaryList(of: jordan)
    let kite = try await builder.item("Kite", on: jordansList, as: jordan)
    let tent = try await builder.item("Tent", on: jordansList, as: jordan)
    let robins = try await builder.claim(
      kite, as: robin, for: graduation, fromLabel: "The Robins", note: "Robin's note about the kite")
    let caseys = try await builder.claim(tent, as: casey, fromLabel: "From Casey", note: "Casey's note about the tent")

    let gifts = [caseysForRobin, robins, caseys]
    return Seeded(
      robin: robin, jordan: jordan, graduation: graduation, recital: recital, reunion: reunion,
      secrets: gifts.map(\.id) + [
        "Casey's label", "Casey's note for Robin", "The Robins", "Robin's note about the kite", "From Casey",
        "Casey's note about the tent", robin.name, casey.name, "Bike", "Kite", "Tent",
      ],
      giftIDs: gifts.map(\.id))
  }

  /// Words that spell out the plan's whole phrase, so the suite sees every value that the words can carry: whose
  /// occasion, and how early. The catalog's words carry only the person, the occasion and the timing: a hosted test
  /// holds them to the table.
  static let words = ReminderWords(title: { "Wishbone" }, body: { "\($0)" })

  // MARK: - Reminders

  @Test("Each reminder's fields equal the allow list, and hold no value from the fixture's gifts")
  func reminders() async throws {
    let fixture = try await fixture()
    let center = RecordingReminderCenter()
    let device = instance.device(reminders: Reminders(center: center, words: Self.words))
    await device.signIn(pasting: try await instance.loginLink(for: fixture.robin))
    let session = try #require(device.session)
    let requests = center.pending

    // The payload is built from the synced copy: the copy holds Robin's gift, and one reminder for each timing of
    // each occasion in the next 60 days.
    await until { session.gifts.count == 1 }
    #expect(requests.count == 8)

    // The fields of the payload, exactly.
    for request in requests {
      #expect(Mirror(reflecting: request).children.map(\.label) == ["identifier", "title", "body", "fires", "repeats"])
    }

    // The identifier: the instance, the user, an occasion of the copy, and the kind. Nothing else.
    let occasions = Set(session.occasions.map(\.id))
    for request in requests {
      let identifier = try #require(ReminderIdentifier(request.identifier))
      #expect(identifier.description == request.identifier)
      #expect(identifier.instance == (try instance.address))
      #expect(identifier.userID == fixture.robin.id)
      #expect(occasions.contains(identifier.occasionID))
    }

    // The words: the occasion and the person only, and the title.
    let jordan = fixture.jordan.name
    let subjects: [ReminderSubject] = [
      .birthday(person: jordan),
      .custom(person: jordan, occasion: fixture.graduation.name),
      .shared(occasion: fixture.reunion.name),
      .ownCustom(occasion: fixture.recital.name),
    ]
    let phrases = subjects.flatMap { subject in
      [EarlyReminder.twoWeeks, nil].map { ReminderPhrase(subject: subject, early: $0) }
    }
    #expect(Set(requests.map(\.body)) == Set(phrases.map { "\($0)" }))
    #expect(requests.allSatisfy { $0.title == "Wishbone" })

    // The trigger: a day and 9:00, with no repeat and no zone.
    for request in requests {
      #expect(!request.repeats)
      #expect(request.fires.hour == 9 && request.fires.minute == 0)
      #expect(request.fires.timeZone == nil && request.fires.second == nil && request.fires.weekday == nil)
    }

    // What the notification center gets: a title and a body, and nothing more.
    for request in requests.map(\.notificationRequest) {
      let content = request.content
      #expect(content.title == "Wishbone")
      #expect(content.subtitle.isEmpty)
      #expect(content.badge == nil)
      #expect(content.sound == nil)
      #expect(content.userInfo.isEmpty)
      #expect(content.attachments.isEmpty)
      #expect(content.categoryIdentifier.isEmpty)
      #expect(content.threadIdentifier.isEmpty)
      #expect(content.targetContentIdentifier == nil)
      // Quiet, with nothing that ranks it, sums it up, focuses it, or shows on launch.
      #expect(content.interruptionLevel == .active)
      #expect(content.relevanceScore == 0)
      #expect(content.summaryArgument.isEmpty)
      #expect(content.summaryArgumentCount == 0)
      #expect(content.filterCriteria == nil)
      #if os(iOS)
        // macOS has no launch image.
        #expect(content.launchImageName.isEmpty)
      #endif
      let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
      #expect(!trigger.repeats)
    }

    // A second net: no text of the payload holds a value from the gifts.
    for request in requests {
      for text in [request.identifier, request.title, request.body] {
        for secret in fixture.secrets where !fixture.giftIDs.contains(secret) {
          #expect(!text.contains(secret), "\(text) holds \(secret)")
        }
      }
      // A gift's ID is a number, so it is looked for as a word of the text. The identifier's numbers are the user
      // and an occasion, which are held above.
      let words = Set((request.title + " " + request.body).split { !$0.isLetter && !$0.isNumber }.map(String.init))
      #expect(words.isDisjoint(with: fixture.giftIDs))
    }
  }
}
