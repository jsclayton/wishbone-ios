import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// The reminder settings, at the session model's seam: the one switch, how early, the one on the day, and Show on
/// Lock Screen. Each change rebuilds the whole set. The settings belong to the session. See "One switch, and the
/// timing", "Turning them on" and "Staying correct" in `docs/spec.md`, and `docs/screens/reminders-settings.md`.
///
/// The notification center is behind a protocol: these tests record what the session asks of it. Each test has a
/// server of its own, so no other test's occasion for everyone is in its set.
@Suite("Reminder settings", .timeLimit(.minutes(2)))
@MainActor
struct ReminderSettingsTests {
  let instance: Instance
  var builder: FixtureBuilder { instance.builder }

  init() async throws {
    instance = try await Instance(server: try await TestServer.start())
  }

  /// Words that spell out the plan's whole phrase, so a test sees how early each reminder says it is.
  static let words = ReminderWords(title: { "Wishbone" }, body: { "\($0)" })

  /// A confirmed user whose birthday is half a year away, so that it gives no reminder on the day a test runs.
  private func person() async throws -> Fixture.Person {
    let birthday = RemindersTests.day(in: 180)
    let person = try await builder.person("Robin", birthday: (birthday.month, birthday.day))
    try await builder.confirmProfile(of: person)
    return person
  }

  /// A custom occasion of the user, `days` from today.
  private func occasion(_ name: String, of person: Fixture.Person, in days: Int) async throws -> Fixture.Occasion {
    let date = RemindersTests.day(in: days)
    return try await builder.customOccasion(name, of: person, year: date.year, month: date.month, day: date.day)
  }

  /// The identifier of one of the occasion's reminders.
  private func identifier(of occasion: Fixture.Occasion, _ kind: ReminderKind, for person: Fixture.Person) throws
    -> String
  {
    ReminderIdentifier(instance: try instance.address, userID: person.id, occasionID: occasion.id, kind: kind)
      .description
  }

  /// A device signed in as the person, with the center. Its first sync has ended.
  private func signedIn(
    as person: Fixture.Person, center: RecordingReminderCenter, storage: SessionStorage = .memory
  ) async throws -> (device: Device, session: SessionModel) {
    let device = instance.device(storage: storage, reminders: Reminders(center: center, words: Self.words))
    await device.signIn(pasting: try await instance.loginLink(for: person))
    return (device, try #require(device.session))
  }

  /// The settings, with one change.
  private static func settings(_ change: (inout ReminderSettings) -> Void) -> ReminderSettings {
    var settings = ReminderSettings()
    change(&settings)
    return settings
  }

  /// The trigger of a reminder `days` from today, at 9:00.
  private static func fires(in days: Int) -> DateComponents {
    let day = RemindersTests.day(in: days)
    return DateComponents(year: day.year, month: day.month, day: day.day, hour: 9, minute: 0)
  }

  // MARK: - 1. The one switch

  @Test("The switch off removes every reminder. On rebuilds the set")
  func oneSwitch() async throws {
    let robin = try await person()
    let graduation = try await occasion("Graduation", of: robin, in: 20)
    let center = RecordingReminderCenter()
    let (_, session) = try await signedIn(as: robin, center: center)
    let both = Set([
      try identifier(of: graduation, .early, for: robin), try identifier(of: graduation, .onTheDay, for: robin),
    ])
    #expect(Set(center.identifiers) == both)

    await session.changeReminderSettings(Self.settings { $0.isOn = false }).value
    #expect(session.reminderSettings.isOn == false)
    #expect(center.pending.isEmpty)

    // A sync while they are off schedules none.
    #expect(await session.syncNow() == .succeeded)
    #expect(center.pending.isEmpty)

    await session.changeReminderSettings(ReminderSettings()).value
    #expect(Set(center.identifiers) == both)
  }

  // MARK: - 2. How early

  @Test("Each early choice moves the early reminders, and changes their words. The one on the day stays")
  func early() async throws {
    let robin = try await person()
    let graduation = try await occasion("Graduation", of: robin, in: 40)
    let center = RecordingReminderCenter()
    let (_, session) = try await signedIn(as: robin, center: center)
    let early = try identifier(of: graduation, .early, for: robin)
    let onTheDay = try identifier(of: graduation, .onTheDay, for: robin)
    let subject = ReminderSubject.ownCustom(occasion: graduation.name)

    for choice in [EarlyReminder.oneWeek, .fourWeeks, .twoWeeks] {
      await session.changeReminderSettings(Self.settings { $0.early = choice }).value
      #expect(session.reminderSettings.early == choice)
      let requests = Dictionary(uniqueKeysWithValues: center.pending.map { ($0.identifier, $0) })
      #expect(Set(requests.keys) == [early, onTheDay], "\(choice)")
      #expect(requests[early]?.fires == Self.fires(in: 40 - choice.rawValue * 7), "\(choice)")
      #expect(requests[early]?.body == "\(ReminderPhrase(subject: subject, early: choice))", "\(choice)")
      #expect(requests[onTheDay]?.fires == Self.fires(in: 40), "\(choice)")
      #expect(requests[onTheDay]?.body == "\(ReminderPhrase(subject: subject, early: nil))", "\(choice)")
    }
  }

  // MARK: - 3. On the day

  @Test("On the day, off, leaves only the early reminders")
  func onTheDayOff() async throws {
    let robin = try await person()
    let graduation = try await occasion("Graduation", of: robin, in: 20)
    let recital = try await occasion("Recital", of: robin, in: 30)
    let center = RecordingReminderCenter()
    let (_, session) = try await signedIn(as: robin, center: center)
    #expect(center.pending.count == 4)

    await session.changeReminderSettings(Self.settings { $0.onTheDay = false }).value
    #expect(
      Set(center.identifiers)
        == [try identifier(of: graduation, .early, for: robin), try identifier(of: recital, .early, for: robin)])

    await session.changeReminderSettings(ReminderSettings()).value
    #expect(center.pending.count == 4)
  }

  // MARK: - 4. Show on Lock Screen

  @Test("Show on Lock Screen is offered only with provisional permission, and asks once")
  func showOnLockScreen() async throws {
    let robin = try await person()
    _ = try await occasion("Graduation", of: robin, in: 20)
    let center = RecordingReminderCenter(authorization: .notDetermined, answer: .authorized)
    let (_, session) = try await signedIn(as: robin, center: center)

    // After the profile gate, the app asked for provisional permission, which iOS gave with no alert. Nothing has
    // asked for full permission.
    #expect(center.asks == 1)
    #expect(center.fullAsks == 0)
    #expect(session.reminderAuthorization == .provisional)
    #expect(center.pending.count == 2)

    // A second tap while the first waits on iOS asks nothing.
    center.hold(.authorization)
    let first = Task { await session.showRemindersOnLockScreen() }
    await center.waitUntilHeld()
    await session.showRemindersOnLockScreen()
    center.release()
    await first.value
    #expect(center.fullAsks == 1)
    #expect(session.reminderAuthorization == .authorized)
    #expect(center.pending.count == 2)

    // With full permission, it is not offered, and a tap asks nothing.
    await session.showRemindersOnLockScreen()
    #expect(center.fullAsks == 1)
    #expect(center.asks == 1)
  }

  @Test("Don't Allow on the system alert turns notifications off: nothing is scheduled, and nothing is asked again")
  func dontAllow() async throws {
    let robin = try await person()
    _ = try await occasion("Graduation", of: robin, in: 20)
    let center = RecordingReminderCenter(authorization: .provisional, answer: .denied)
    let (_, session) = try await signedIn(as: robin, center: center)
    #expect(center.pending.count == 2)

    await session.showRemindersOnLockScreen()
    #expect(center.fullAsks == 1)
    #expect(session.reminderAuthorization == .denied)
    #expect(center.pending.isEmpty)

    await session.showRemindersOnLockScreen()
    #expect(await session.syncNow() == .succeeded)
    #expect(center.fullAsks == 1)
    #expect(center.asks == 0)
    #expect(center.pending.isEmpty)
  }

  // MARK: - 5. Notifications off in iOS

  @Test("With notifications off in iOS, no change of setting schedules anything, and nothing is asked")
  func notificationsOff() async throws {
    let robin = try await person()
    _ = try await occasion("Graduation", of: robin, in: 20)
    let center = RecordingReminderCenter(authorization: .denied)
    let (_, session) = try await signedIn(as: robin, center: center)
    #expect(session.reminderAuthorization == .denied)

    for settings in [
      Self.settings { $0.isOn = false }, ReminderSettings(), Self.settings { $0.early = .oneWeek },
      Self.settings { $0.onTheDay = false },
    ] {
      await session.changeReminderSettings(settings).value
      #expect(center.pending.isEmpty)
    }
    await session.showRemindersOnLockScreen()
    #expect(center.pending.isEmpty)
    #expect(center.asks == 0)
    #expect(center.fullAsks == 0)

    // The user turns notifications on in iOS Settings. The screen reads it again when the app comes back.
    center.set(authorization: .provisional)
    await session.readReminderAuthorization()
    #expect(session.reminderAuthorization == .provisional)
  }

  // MARK: - 6. They belong to the session

  @Test("The settings are kept across a launch, and through a copy that the schema number drops. Sign-out removes them")
  func keptBySession() async throws {
    let robin = try await person()
    _ = try await occasion("Graduation", of: robin, in: 20)
    let folder = try ScratchDirectory("device")
    let chosen = ReminderSettings(isOn: true, early: .oneWeek, onTheDay: false)
    do {
      let (_, session) = try await signedIn(as: robin, center: RecordingReminderCenter(), storage: .folder(folder.url))
      #expect(session.reminderSettings == ReminderSettings())
      await session.changeReminderSettings(chosen).value
    }

    // The next launch drops the copy, whose schema number is another. The settings stay.
    try DatabaseFile(under: folder.url).execute("PRAGMA user_version = 0")
    let center = RecordingReminderCenter()
    let device = instance.device(storage: .folder(folder.url), reminders: Reminders(center: center))
    let session = try #require(device.session)
    #expect(session.reminderSettings == chosen)

    // After sign-out, the next session of the same user has the defaults.
    await device.signOut()
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    #expect(try #require(device.session).reminderSettings == ReminderSettings())
  }

  // MARK: - 7. A sign-out while the session waits on iOS

  @Test(
    "A sign-out while a rebuild waits on iOS leaves no reminder: held in authorization(), or in replacePending",
    arguments: [RecordingReminderCenter.Call.authorization, .replacePending])
  func signOutDuringRebuild(_ call: RecordingReminderCenter.Call) async throws {
    let robin = try await person()
    _ = try await occasion("Graduation", of: robin, in: 20)
    let center = RecordingReminderCenter()
    let (device, session) = try await signedIn(as: robin, center: center)
    #expect(center.pending.count == 2)

    // A change of setting starts a rebuild, which iOS holds.
    center.hold(call)
    let rebuild = session.changeReminderSettings(Self.settings { $0.early = .oneWeek })
    await center.waitUntilHeld()

    // The sign-out has forgotten the session, and waits for the rebuild before it removes every reminder.
    let removals = center.removals
    let signOut = Task { await device.signOut() }
    await until { device.session == nil }
    center.release()
    await signOut.value
    await rebuild.value

    #expect(center.pending.isEmpty)
    #expect(center.removals == removals + 1)
    // A rebuild held before it scheduled schedules nothing after the sign-out.
    if call == .authorization { #expect(center.replaces == 1) }
  }
}
