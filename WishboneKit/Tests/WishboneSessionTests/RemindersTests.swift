import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// The reminders, at the session model's seam: the app rebuilds the whole set after every sync that succeeded, and
/// leaves it after one that failed. Sign-out, the API's own 401 and a fresh install remove every reminder. After
/// sign-in and the profile gate, the app asks for provisional authorization, once. See "Turning them on" and "Staying
/// correct" in `docs/spec.md`.
///
/// The notification center is behind a protocol: these tests record what the session asks of it. Each test has a
/// server of its own, so no other test's occasion for everyone is in its set.
@Suite("Reminders", .timeLimit(.minutes(2)))
@MainActor
struct RemindersTests {
  let instance: Instance
  var builder: FixtureBuilder { instance.builder }

  init() async throws {
    instance = try await Instance(server: try await TestServer.start())
  }

  /// The day that is `days` from today, in UTC: the zone of the devices and of the users of these tests.
  static func day(in days: Int) -> (year: Int, month: Int, day: Int) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let date = calendar.date(byAdding: .day, value: days, to: Date())!
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return (parts.year!, parts.month!, parts.day!)
  }

  /// A user whose birthday is half a year away, so that it gives no reminder on the day a test runs.
  private func person(_ name: String = "Robin", confirmed: Bool = true) async throws -> Fixture.Person {
    let birthday = Self.day(in: 180)
    let person = try await builder.person(name, birthday: (birthday.month, birthday.day))
    if confirmed { try await builder.confirmProfile(of: person) }
    return person
  }

  /// A custom occasion of the user, `days` from today.
  private func occasion(_ name: String, of person: Fixture.Person, in days: Int) async throws -> Fixture.Occasion {
    let date = Self.day(in: days)
    return try await builder.customOccasion(name, of: person, year: date.year, month: date.month, day: date.day)
  }

  /// The identifiers of the occasions' reminders, both of each.
  private func identifiers(of occasions: Fixture.Occasion..., for person: Fixture.Person) throws -> Set<String> {
    let address = try instance.address
    return Set(
      occasions.flatMap { occasion in
        ReminderKind.allCases.map {
          ReminderIdentifier(instance: address, userID: person.id, occasionID: occasion.id, kind: $0).description
        }
      })
  }

  /// A device signed in as the person, with the center. Its first sync has ended.
  private func signedIn(
    as person: Fixture.Person, center: RecordingReminderCenter, storage: SessionStorage = .memory
  ) async throws -> (device: Device, session: SessionModel) {
    let device = instance.device(storage: storage, reminders: Reminders(center: center))
    await device.signIn(pasting: try await instance.loginLink(for: person))
    return (device, try #require(device.session))
  }

  // MARK: - 5. Rebuilt after a sync

  @Test("After a sync, the pending set is replaced. After a failed sync, it is as it was")
  func rebuiltAfterSync() async throws {
    let robin = try await person()
    let graduation = try await occasion("Graduation", of: robin, in: 20)
    let center = RecordingReminderCenter()
    // An earlier session left a reminder. The first rebuild replaces it.
    center.set(pending: [ReminderRequest(try stale, words: .none)])
    let (_, session) = try await signedIn(as: robin, center: center)
    #expect(Set(center.identifiers) == (try identifiers(of: graduation, for: robin)))

    // The graduation goes, and a recital comes. The next sync replaces the whole set.
    let recital = try await occasion("Recital", of: robin, in: 30)
    try await robin.signedIn().send("DELETE", "/occasions/\(graduation.id)").expecting(204)
    #expect(await session.syncNow() == .succeeded)
    #expect(Set(center.identifiers) == (try identifiers(of: recital, for: robin)))

    // A sync that fails leaves the set as it is.
    let replaces = center.replaces
    let party = try await occasion("Party", of: robin, in: 40)
    instance.conditioner.dropEverything()
    #expect(await session.syncNow() == .unreachable)
    #expect(Set(center.identifiers) == (try identifiers(of: recital, for: robin)))
    #expect(center.replaces == replaces)

    // The next sync that succeeds brings the party.
    instance.conditioner.passEverything()
    #expect(await session.syncNow() == .succeeded)
    #expect(Set(center.identifiers) == (try identifiers(of: recital, party, for: robin)))
  }

  @Test("A rebuild that waits for iOS holds no sync: the next sync runs at once, and finds the instance gone")
  func slowCenterHoldsNoSync() async throws {
    let robin = try await person()
    let center = HeldReminderCenter()
    let device = instance.device(reminders: Reminders(center: center))
    let link = try await instance.loginLink(for: robin)
    let signingIn = Task { await device.signIn(pasting: link) }
    // The sync at sign-in succeeded, and its rebuild waits for iOS to answer the ask.
    await center.waitUntilAsked()
    let session = try #require(device.session)

    // The instance goes away, and the window comes to the foreground. The sync doesn't wait for the rebuild: the
    // line shows while iOS has not answered. A sync that waited would hold the line until the suite's time limit.
    instance.conditioner.dropEverything()
    let syncing = Task { await session.syncNow() }
    await until { session.isInstanceUnreachable }
    #expect(session.isInstanceUnreachable)

    // The sign-in ends when iOS answers.
    center.answer()
    #expect(await syncing.value == .unreachable)
    await signingIn.value
  }

  @Test("With notifications off for the app in iOS, a sync schedules none, and asks for nothing")
  func notificationsOff() async throws {
    let robin = try await person()
    _ = try await occasion("Graduation", of: robin, in: 20)
    let center = RecordingReminderCenter(authorization: .denied)
    let (_, session) = try await signedIn(as: robin, center: center)
    #expect(center.pending.isEmpty)
    #expect(await session.syncNow() == .succeeded)
    #expect(center.pending.isEmpty)
    #expect(center.asks == 0)
  }

  /// A reminder that an earlier session scheduled, for an occasion in 9 days.
  private var stale: PlannedReminder {
    get throws {
      let earlier = Session(instance: try #require(InstanceAddress("https://old.example")), token: "old", userID: "1")
      let date = Self.day(in: 9)
      let text = [date.year, date.month, date.day].map { $0 < 10 ? "0\($0)" : "\($0)" }.joined(separator: "-")
      let occasion = ReminderPlan.Occasion(id: "2", kind: .shared, name: "Old", userID: nil, nextDate: text)
      let plan = ReminderPlan.reminders(
        for: [occasion], names: [:], session: earlier, settings: ReminderSettings(), now: Date(), timeZone: .gmt)
      return try #require(plan.first)
    }
  }

  // MARK: - 6. Removed at the end of the session

  @Test("Sign-out removes every reminder")
  func signOutRemovesEvery() async throws {
    let robin = try await person()
    _ = try await occasion("Graduation", of: robin, in: 20)
    let center = RecordingReminderCenter()
    let (device, _) = try await signedIn(as: robin, center: center)
    #expect(center.pending.count == 2)
    let removals = center.removals

    await device.signOut()
    #expect(center.pending.isEmpty)
    #expect(center.removals == removals + 1)
  }

  @Test("The API's own 401 removes every reminder")
  func endedByServerRemovesEvery() async throws {
    let robin = try await person()
    _ = try await occasion("Graduation", of: robin, in: 20)
    let center = RecordingReminderCenter()
    let (device, session) = try await signedIn(as: robin, center: center)
    #expect(center.pending.count == 2)

    // Another session revokes this one, as the Devices list in a browser does.
    let other = try robin.signedIn()
    let sessions = try await other.all("/users/me/sessions")
    let current = try #require(
      sessions.first { $0["is_current"].bool == false && $0["user_agent"].string?.hasPrefix("Wishbone iOS/") == true })
    _ = try await other.send("DELETE", "/users/me/sessions/\(try #require(current["id"].string))").expecting(204)
    await session.syncNow()

    #expect(device.session == nil)
    #expect(center.pending.isEmpty)
  }

  @Test("A fresh install removes every reminder: a session with no marker, and a device with no session")
  func freshInstallRemovesEvery() async throws {
    let robin = try await person()
    _ = try await occasion("Graduation", of: robin, in: 20)
    let center = RecordingReminderCenter()
    _ = try await signedIn(as: robin, center: center)
    #expect(center.pending.count == 2)

    // A reinstall: the Keychain item is left, and the marker is gone.
    let reinstalled = instance.device(marker: InMemoryInstallMarker(), reminders: Reminders(center: center))
    #expect(reinstalled.session == nil)
    #expect(center.pending.isEmpty)
    await reinstalled.launchEnded()

    // A device with no session at all removes them too.
    center.set(pending: [ReminderRequest(try stale, words: .none)])
    let signedOut = Device(
      Device.Setup(
        userAgent: UserAgent(version: "1.0", isPad: false), keychain: InMemorySessionKeychain(),
        marker: InMemoryInstallMarker(), storage: .memory, reminders: Reminders(center: center)))
    #expect(signedOut.session == nil)
    #expect(center.pending.isEmpty)
  }

  // MARK: - 7. Provisional authorization, once

  @Test("Provisional authorization is asked once, after sign-in and the gate, and never again")
  func provisionalOnce() async throws {
    let robin = try await person(confirmed: false)
    let graduation = try await occasion("Graduation", of: robin, in: 20)
    let center = RecordingReminderCenter(authorization: .notDetermined)
    let folder = try ScratchDirectory("device")
    let (_, session) = try await signedIn(as: robin, center: center, storage: .folder(folder.url))

    // While the gate shows, a sync asks for nothing, and schedules nothing.
    #expect(session.needsProfileGate)
    #expect(await session.syncNow() == .succeeded)
    #expect(center.asks == 0)
    #expect(center.pending.isEmpty)

    // Continue asks, and the reminders are scheduled.
    let user = try #require(session.user)
    #expect(await session.confirmProfile(ProfileDraft(user)) == .confirmed)
    #expect(center.asks == 1)
    #expect(Set(center.identifiers) == (try identifiers(of: graduation, for: robin)))

    // Never again: not at the next sync, and not at the next launch.
    #expect(await session.syncNow() == .succeeded)
    let relaunched = instance.device(storage: .folder(folder.url), reminders: Reminders(center: center))
    #expect(try await #require(relaunched.session).syncNow() == .succeeded)
    #expect(center.asks == 1)
  }

  @Test("A user with no gate is asked right after sign-in, once")
  func provisionalAfterSignIn() async throws {
    let robin = try await person()
    let graduation = try await occasion("Graduation", of: robin, in: 20)
    let center = RecordingReminderCenter(authorization: .notDetermined)
    let (_, session) = try await signedIn(as: robin, center: center)
    #expect(center.asks == 1)
    #expect(Set(center.identifiers) == (try identifiers(of: graduation, for: robin)))

    #expect(await session.syncNow() == .succeeded)
    #expect(center.asks == 1)
  }
}
