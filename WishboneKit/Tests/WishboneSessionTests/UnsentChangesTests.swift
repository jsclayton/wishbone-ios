import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// The unsent changes, with mark bought as the first: the journal, the send, a pull meanwhile, a refusal, sign-out,
/// the API's own 401, and a migration that drops the copy. See ADR 0006, "Unsent changes" and "Unsent changes,
/// sign-out, and late refusals" in `docs/spec.md`, and "Mark bought" in `docs/screens/gifts.md`.
@Suite("Unsent changes", .timeLimit(.minutes(2)))
@MainActor
struct UnsentChangesTests {
  typealias Route = NetworkConditioner.Route

  static let patchGift = Route("PATCH", "/gifts/{id}")
  static let versions = Route("GET", "/versions")
  static let revoke = Route("DELETE", "/users/me/sessions/current")

  let instance: Instance

  /// The one window of the app, as it comes to the foreground.
  let window = UUID()

  init() async throws {
    instance = try await Instance()
  }

  /// A giver with one open gift, not bought, on an item of a person in their group. A second item on the same
  /// list is free to claim.
  private struct Seeded {
    let giver: Fixture.Person
    let recipient: Fixture.Person
    let gift: Fixture.Gift
    let free: Fixture.Item
  }

  private func seed() async throws -> Seeded {
    let builder = instance.builder
    let robin = try await builder.person("Robin")
    let morgan = try await builder.person("Morgan")
    _ = try await builder.group("Family", users: [robin, morgan])
    let list = try await builder.primaryList(of: morgan)
    let kite = try await builder.item("Kite", on: list, as: morgan)
    let free = try await builder.item("Ball", on: list, as: morgan)
    let gift = try await builder.claim(kite, as: robin)
    return Seeded(giver: robin, recipient: morgan, gift: gift, free: free)
  }

  /// A device of the instance, signed in as the person, with the gift in its copy.
  private func signedIn(
    as person: Fixture.Person, with gift: Fixture.Gift, storage: SessionStorage = .memory,
    diagnostics: any DiagnosticsReporter = .none
  ) async throws -> Device {
    let device = instance.device(storage: storage, diagnostics: diagnostics)
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    await until { session.gift(id: gift.id) != nil }
    return device
  }

  /// The gift's mark, as the server has it for its giver.
  private func boughtOnServer(_ gift: Fixture.Gift) async throws -> Bool? {
    try await gift.giver.signedIn().get("/gifts/\(gift.id)")["is_bought"].bool
  }

  private var requests: [NetworkConditioner.SeenRequest] {
    instance.conditioner.requests
  }

  /// How many requests on the route came after the last one on `after`.
  private func count(_ route: Route, afterTheLast after: Route) -> Int {
    let seen = requests
    guard let last = seen.lastIndex(where: { $0.isOn(after) }) else { return 0 }
    return seen[(last + 1)...].count { $0.isOn(route) }
  }

  private func sessionsFolder(in folder: ScratchDirectory) -> String {
    folder.url.appending(path: "Sessions").path(percentEncoded: false)
  }

  // MARK: - 1. At once, then sent

  @Test("Mark bought shows in the copy at once. After the send, the server has it, and the journal is empty")
  func showsAtOnceThenSent() async throws {
    let seeded = try await seed()
    let device = try await signedIn(as: seeded.giver, with: seeded.gift)
    let session = try #require(device.session)
    #expect(session.gift(id: seeded.gift.id)?.isBought == .shown(false))

    await session.markBought(gift: seeded.gift.id, true)

    // At once, before anything is sent: the gift, its row in Giving, and its page.
    #expect(session.gift(id: seeded.gift.id)?.isBought == .shown(true))
    #expect(session.giving.first { $0.id == seeded.gift.id }?.isBought == .shown(true))
    #expect(session.giftPage(id: seeded.gift.id)?.gift.isBought == .shown(true))
    #expect(session.unsentChangeCount == 1)

    await until { session.unsentChangeCount == 0 }
    #expect(try await boughtOnServer(seeded.gift) == true)
    #expect(session.gift(id: seeded.gift.id)?.isBought == .shown(true))

    // And back: not bought.
    await session.markBought(gift: seeded.gift.id, false)
    #expect(session.gift(id: seeded.gift.id)?.isBought == .shown(false))
    await until { session.unsentChangeCount == 0 }
    #expect(try await boughtOnServer(seeded.gift) == false)
  }

  // MARK: - 2. Offline, through a relaunch

  @Test(
    """
    With the network dropped, the change stays through a relaunch, the line counts 1, and it is sent when the \
    network is back
    """
  )
  func offlineThroughARelaunch() async throws {
    let seeded = try await seed()
    let folder = try ScratchDirectory("device")
    do {
      // The device goes at the end of this scope, as the app does when it ends.
      let device = try await signedIn(as: seeded.giver, with: seeded.gift, storage: .folder(folder.url))
      let session = try #require(device.session)
      instance.conditioner.dropEverything()
      await session.markBought(gift: seeded.gift.id, true)
      await until { session.isInstanceUnreachable }
      await until { session.unsentChangeCount == 1 }
      #expect(session.screenState(hasRows: true) == .saved(cantReach: true))
    }

    let relaunched = instance.device(storage: .folder(folder.url))
    let session = try #require(relaunched.session)
    // What is saved shows at once: the change, over the copy, and its count.
    #expect(session.gift(id: seeded.gift.id)?.isBought == .shown(true))
    #expect(session.unsentChangeCount == 1)
    await session.syncNow()
    #expect(session.isInstanceUnreachable)
    #expect(session.unsentChangeCount == 1)
    #expect(try await boughtOnServer(seeded.gift) == false)

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    #expect(!session.isInstanceUnreachable)
    #expect(try await boughtOnServer(seeded.gift) == true)
    #expect(session.gift(id: seeded.gift.id)?.isBought == .shown(true))
  }

  // MARK: - 3. A pull while it waits

  @Test("A pull while the change waits does not undo it")
  func pullDoesNotUndo() async throws {
    let seeded = try await seed()
    let device = try await signedIn(as: seeded.giver, with: seeded.gift)
    let session = try #require(device.session)
    // The recipient renames the item, so the next pull fetches the gift again, with its mark as the server has it.
    try await seeded.recipient.signedIn().send(
      "PATCH", "/items/\(seeded.gift.item.id)", json: ["title": "Red kite"]
    ).expecting(200)

    // A sync is in its pull when the giver marks the gift bought. The change can't be sent yet.
    let pulling = instance.conditioner.hold(Self.versions)
    let sending = instance.conditioner.hold(Self.patchGift, at: .request)
    let sync = Task { await session.syncNow() }
    await pulling.waitUntilHeld()
    await session.markBought(gift: seeded.gift.id, true)
    pulling.release()
    _ = await sync.value

    // The pull wrote the gift again, as the server has it: renamed, and not bought. The change still shows over
    // it, and still waits.
    await until { session.gift(id: seeded.gift.id)?.title == "Red kite" }
    #expect(session.gift(id: seeded.gift.id)?.isBought == .shown(true))
    await sending.waitUntilHeld()
    #expect(session.unsentChangeCount == 1)
    #expect(session.gift(id: seeded.gift.id)?.isBought == .shown(true))

    sending.release()
    await until { session.unsentChangeCount == 0 }
    #expect(try await boughtOnServer(seeded.gift) == true)
    #expect(session.gift(id: seeded.gift.id)?.isBought == .shown(true))
  }

  // MARK: - 4. An answer in flight

  @Test(
    """
    An answer that the conditioner holds wins over a pull for the same gift. After it, the server is the authority \
    again
    """
  )
  func answerInFlightWins() async throws {
    let seeded = try await seed()
    let device = try await signedIn(as: seeded.giver, with: seeded.gift)
    let session = try #require(device.session)

    let answer = instance.conditioner.hold(Self.patchGift)
    await session.markBought(gift: seeded.gift.id, true)
    await answer.waitUntilHeld()
    // The server has the change, and its answer is in flight. Meanwhile, the giver clears the mark in a browser.
    try await seeded.giver.signedIn().send("PATCH", "/gifts/\(seeded.gift.id)", json: ["is_bought": false])
      .expecting(200)

    // While the answer is held, the change still shows, and still waits.
    #expect(session.gift(id: seeded.gift.id)?.isBought == .shown(true))
    #expect(session.unsentChangeCount == 1)

    // A sync is asked for, and the answer comes. The change leaves the journal, and the gift ends as the server has
    // it now: not bought. An answer written over a later pull would leave it bought.
    let pull = Task { await session.syncNow() }
    answer.release()
    _ = await pull.value
    await until { session.unsentChangeCount == 0 }
    await until { session.gift(id: seeded.gift.id)?.isBought == .shown(false) }
    #expect(try await boughtOnServer(seeded.gift) == false)
  }

  // MARK: - 5. A late refusal

  @Test(
    """
    A change that the server refuses is rolled back, shows once at the next foreground with its code, is captured \
    by its route and code, and never shows again
    """
  )
  func lateRefusal() async throws {
    let seeded = try await seed()
    let diagnostics = RecordingDiagnostics()
    let folder = try ScratchDirectory("device")
    let device = try await signedIn(
      as: seeded.giver, with: seeded.gift, storage: .folder(folder.url), diagnostics: diagnostics)
    let session = try #require(device.session)

    // Offline, the giver marks the gift bought. Meanwhile it is given: the server no longer lets them change it.
    instance.conditioner.dropEverything()
    await session.markBought(gift: seeded.gift.id, true)
    await until { session.isInstanceUnreachable }
    #expect(session.gift(id: seeded.gift.id)?.isBought == .shown(true))
    #expect(try await instance.builder.reveal(giftsFor: seeded.recipient) >= 1)

    instance.conditioner.passEverything()
    await session.syncNow()

    // Rolled back: the journal is empty, and the gift is the server's, given and not bought.
    await until { session.unsentChangeCount == 0 }
    await until { session.gift(id: seeded.gift.id)?.state == .given }
    #expect(session.gift(id: seeded.gift.id)?.isBought == .shown(false))
    #expect(try await boughtOnServer(seeded.gift) == false)
    await until { session.lateRefusals.count == 1 }
    #expect(session.lateRefusalAlert == nil)
    #expect(diagnostics.faults == [.refusedWrite(.updateGift, code: "forbidden")])

    // The next foreground shows it, in that window, with what it was and the server's code.
    await session.cameToForeground(window: window)
    let alert = try #require(session.lateRefusalAlert)
    #expect(alert.window == window)
    #expect(alert.refusals.count == 1)
    let refusal = try #require(alert.refusals.first)
    #expect(refusal.action == .markBought(giftID: seeded.gift.id, isBought: true))
    #expect(refusal.title == seeded.gift.item.title)
    #expect(refusal.refusal.code == .forbidden)
    #expect(refusal.refusal.status == 403)
    #expect(refusal.refusal.route == .updateGift)
    session.lateRefusalsShown(in: window)
    #expect(session.lateRefusalAlert == nil)

    // Never again: not at the next foreground, and not after a relaunch.
    session.leftForeground(window: window)
    await session.cameToForeground(window: window)
    #expect(session.lateRefusalAlert == nil)
    await until { session.lateRefusals.isEmpty }
    let relaunched = instance.device(storage: .folder(folder.url))
    let again = try #require(relaunched.session)
    #expect(again.lateRefusals.isEmpty)
    await again.cameToForeground(window: window)
    #expect(again.lateRefusalAlert == nil)
  }

  @Test("A late 404 is rolled back and shown, and is not captured")
  func lateNotFound() async throws {
    let seeded = try await seed()
    let diagnostics = RecordingDiagnostics()
    let device = try await signedIn(as: seeded.giver, with: seeded.gift, diagnostics: diagnostics)
    let session = try #require(device.session)

    instance.conditioner.dropEverything()
    await session.markBought(gift: seeded.gift.id, true)
    await until { session.isInstanceUnreachable }
    // Meanwhile, the giver unclaims the gift in a browser.
    try await seeded.giver.signedIn().send("DELETE", "/gifts/\(seeded.gift.id)").expecting(204)

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    await until { session.gift(id: seeded.gift.id) == nil }
    await until { session.lateRefusals.count == 1 }
    #expect(diagnostics.faults.isEmpty)

    await session.cameToForeground(window: window)
    #expect(session.lateRefusalAlert?.refusals.map(\.refusal.code) == [.notFound])
  }

  /// A giver whose late refusal waits for a window: they marked the gift bought offline, and it was unclaimed in a
  /// browser meanwhile.
  private func aLateRefusalWaits() async throws -> (Device, SessionModel) {
    let seeded = try await seed()
    let device = try await signedIn(as: seeded.giver, with: seeded.gift)
    let session = try #require(device.session)
    instance.conditioner.dropEverything()
    await session.markBought(gift: seeded.gift.id, true)
    await until { session.isInstanceUnreachable }
    try await seeded.giver.signedIn().send("DELETE", "/gifts/\(seeded.gift.id)").expecting(204)
    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.lateRefusals.count == 1 }
    return (device, session)
  }

  @Test(
    """
    An alert of late refusals stays in its window while that window is in the foreground, or only inactive. When \
    two windows come back from Control Center in either order, it doesn't move
    """
  )
  func lateRefusalAlertStays() async throws {
    let (_, session) = try await aLateRefusalWaits()

    // The alert shows in the window. It stays there when another window comes to the foreground beside it.
    await session.cameToForeground(window: window)
    let shown = try #require(session.lateRefusalAlert)
    #expect(shown.window == window)
    let other = UUID()
    await session.cameToForeground(window: other)
    #expect(session.lateRefusalAlert == shown)

    // Control Center makes both windows inactive. The other one comes back first: the alert stays.
    session.leftForeground(window: window)
    session.leftForeground(window: other)
    await session.cameToForeground(window: other)
    await session.cameToForeground(window: window)
    #expect(session.lateRefusalAlert == shown)

    // And again, with the window of the alert first.
    session.leftForeground(window: other)
    session.leftForeground(window: window)
    await session.cameToForeground(window: window)
    await session.cameToForeground(window: other)
    #expect(session.lateRefusalAlert == shown)

    // The other window can't close it. Its own window can, once, and it never shows again.
    session.lateRefusalsShown(in: other)
    #expect(session.lateRefusalAlert == shown)
    session.lateRefusalsShown(in: window)
    #expect(session.lateRefusalAlert == nil)
    session.leftForeground(window: other)
    await session.cameToForeground(window: other)
    #expect(session.lateRefusalAlert == nil)
  }

  @Test(
    """
    When the window of an alert of late refusals goes to the background, or closes, before the alert does, the next \
    window that comes to the foreground shows it, once. The window it left can't close it there
    """
  )
  func lateRefusalAlertMoves() async throws {
    let (_, session) = try await aLateRefusalWaits()
    await session.cameToForeground(window: window)
    let shown = try #require(session.lateRefusalAlert)
    #expect(shown.window == window)

    // The window goes to the background. The next window that comes to the foreground shows the alert.
    let other = UUID()
    session.wentToBackground(window: window)
    await session.cameToForeground(window: other)
    #expect(session.lateRefusalAlert?.window == other)
    #expect(session.lateRefusalAlert?.refusals == shown.refusals)

    // As the alert leaves the first window, SwiftUI says that the first window's alert closed. It still shows in
    // the other one.
    session.lateRefusalsShown(in: window)
    #expect(session.lateRefusalAlert?.window == other)

    // The other window closes before the alert does. The first window, back in the foreground, shows it.
    session.wentToBackground(window: other)
    await session.cameToForeground(window: window)
    #expect(session.lateRefusalAlert?.window == window)
    #expect(session.lateRefusalAlert?.refusals == shown.refusals)
    session.lateRefusalsShown(in: other)
    #expect(session.lateRefusalAlert?.window == window)

    // Closed in its window, it never shows again.
    session.lateRefusalsShown(in: window)
    session.wentToBackground(window: window)
    await session.cameToForeground(window: other)
    #expect(session.lateRefusalAlert == nil)
  }

  // MARK: - 6. What goes on the wire

  @Test("The request is a merge patch with only is_bought, with a key of its own and no If-Match")
  func mergePatch() async throws {
    let seeded = try await seed()
    let device = try await signedIn(as: seeded.giver, with: seeded.gift)
    let session = try #require(device.session)

    await session.markBought(gift: seeded.gift.id, true)
    await until { session.unsentChangeCount == 0 }

    let patches = requests.filter { $0.isOn(Self.patchGift) }
    let patch = try #require(patches.first)
    #expect(patches.count == 1)
    #expect(patch.target.hasSuffix("/gifts/\(seeded.gift.id)"))
    let body = try JSONSerialization.jsonObject(with: patch.body) as? [String: Any]
    #expect(body?.keys.sorted() == ["is_bought"])
    #expect(body?["is_bought"] as? Bool == true)
    #expect(patch.headers["if-match"] == nil)
    #expect(patch.headers["idempotency-key"]?.isEmpty == false)
  }

  // MARK: - 7. Sign out

  @Test("Sign out with a change waiting: the count warns, the app tries to send, and then discards it")
  func signOutDiscards() async throws {
    let seeded = try await seed()
    let folder = try ScratchDirectory("device")
    let device = try await signedIn(as: seeded.giver, with: seeded.gift, storage: .folder(folder.url))
    let session = try #require(device.session)
    instance.conditioner.dropEverything()
    await session.markBought(gift: seeded.gift.id, true)
    await until { session.isInstanceUnreachable }
    // The warning's count.
    await until { session.unsentChangeCount == 1 }

    // The instance answers again, but the change can't get through.
    instance.conditioner.passEverything()
    instance.conditioner.answer(Self.patchGift, with: NetworkConditioner.CannedAnswer(status: 503))
    await device.signOut()

    // It tried to send, then revoked the session, and forgot everything with the change.
    let seen = requests
    let tried = try #require(seen.lastIndex { $0.isOn(Self.patchGift) })
    let revoked = try #require(seen.lastIndex { $0.isOn(Self.revoke) })
    #expect(tried < revoked)
    #expect(device.session == nil)
    #expect(device.signInState == .plain)
    #expect(!FileManager.default.fileExists(atPath: sessionsFolder(in: folder)))
    #expect(session.unsentChangeCount == 0)
    #expect(try await boughtOnServer(seeded.gift) == false)
  }

  @Test("Sign out sends a change that waits, when it can, before it revokes the session")
  func signOutSendsFirst() async throws {
    let seeded = try await seed()
    let device = try await signedIn(as: seeded.giver, with: seeded.gift)
    let session = try #require(device.session)
    instance.conditioner.dropEverything()
    await session.markBought(gift: seeded.gift.id, true)
    await until { session.isInstanceUnreachable }

    instance.conditioner.passEverything()
    await device.signOut()

    #expect(device.session == nil)
    #expect(device.signInState == .plain)
    #expect(try await boughtOnServer(seeded.gift) == true)
  }

  // MARK: - 8. The API's own 401

  @Test("The API's own 401 discards the journal, while the change's answer is still held")
  func unauthorizedDiscards() async throws {
    let seeded = try await seed()
    let folder = try ScratchDirectory("device")
    let device = try await signedIn(as: seeded.giver, with: seeded.gift, storage: .folder(folder.url))
    let session = try #require(device.session)

    // The change reaches the server, and its answer is held.
    let answer = instance.conditioner.hold(Self.patchGift)
    await session.markBought(gift: seeded.gift.id, true)
    await answer.waitUntilHeld()

    // The session is revoked from a browser. The next request gets the API's own 401.
    let other = try seeded.giver.signedIn()
    let sessions = try await other.all("/users/me/sessions")
    let own = try #require(
      sessions.first { $0["is_current"].bool == false && $0["user_agent"].string?.hasPrefix("Wishbone iOS/") == true })
    _ = try await other.send("DELETE", "/users/me/sessions/\(try #require(own["id"].string))").expecting(204)
    #expect(await session.claim(item: seeded.free.id) == .failed)

    #expect(device.session == nil)
    #expect(device.signInState == .signedOutByServer(try instance.address))
    #expect(!FileManager.default.fileExists(atPath: sessionsFolder(in: folder)))
    #expect(session.unsentChangeCount == 0)
    #expect(instance.device(storage: .folder(folder.url)).session == nil)
  }

  // MARK: - 9. A migration that drops the copy

  @Test("A migration that drops the copy keeps the journal, and the change is sent")
  func migrationKeepsTheJournal() async throws {
    let seeded = try await seed()
    let folder = try ScratchDirectory("device")
    do {
      // The device goes at the end of this scope, as the app does when it ends.
      let device = try await signedIn(as: seeded.giver, with: seeded.gift, storage: .folder(folder.url))
      let session = try #require(device.session)
      instance.conditioner.dropEverything()
      await session.markBought(gift: seeded.gift.id, true)
      await until { session.isInstanceUnreachable }
    }
    // The copy has another schema number: the next launch drops it.
    try DatabaseFile(under: folder.url).execute("PRAGMA user_version = 1")

    let diagnostics = RecordingDiagnostics()
    let relaunched = instance.device(storage: .folder(folder.url), diagnostics: diagnostics)
    let session = try #require(relaunched.session)
    #expect(diagnostics.faults.contains(.copyDropped(from: 1, to: 5)))
    // The copy is gone, and the change is not.
    #expect(session.gift(id: seeded.gift.id) == nil)
    #expect(session.unsentChangeCount == 1)

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    #expect(try await boughtOnServer(seeded.gift) == true)
    await until { session.gift(id: seeded.gift.id)?.isBought == .shown(true) }
  }

  // MARK: - 10. The sync after the last one

  @Test("One sync runs after the last change is sent")
  func oneSyncAfterTheLast() async throws {
    let seeded = try await seed()
    let diagnostics = RecordingDiagnostics()
    let device = try await signedIn(as: seeded.giver, with: seeded.gift, diagnostics: diagnostics)
    let session = try #require(device.session)
    let ended = { diagnostics.breadcrumbs.count { $0.kind == .syncEnded } }
    let started = { diagnostics.breadcrumbs.count { $0.kind == .syncStarted } }

    // Two changes wait offline. Each one's sync can't reach the instance. The diagnostics are not observed, so the
    // wait reads whether a sync runs too: a sync's end leaves its breadcrumb before it stops running.
    instance.conditioner.dropEverything()
    let before = ended()
    await session.markBought(gift: seeded.gift.id, true)
    await until { !session.isSyncing && ended() == before + 1 }
    await session.markBought(gift: seeded.gift.id, false)
    await until { !session.isSyncing && ended() == before + 2 }
    await until { session.unsentChangeCount == 2 }

    // The network is back: one sync sends both, in order, and pulls once after the last.
    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    #expect(started() == ended())
    #expect(started() == before + 3)
    let patches = requests.filter { $0.isOn(Self.patchGift) }
    #expect(patches.count == 2)
    #expect(
      patches.compactMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Bool] }
        == [["is_bought": true], ["is_bought": false]])
    #expect(count(Self.versions, afterTheLast: Self.patchGift) == 1)
    #expect(try await boughtOnServer(seeded.gift) == false)
  }
}
