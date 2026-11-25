import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// The fields that a giver changes on a gift's page: the from label and the note, each an unsent change, and how
/// many, which lowers as an unsent change and raises only after the server answers. See "Unsent changes" and "Claims
/// are online only" in `docs/spec.md`, and `docs/screens/gift.md`.
@Suite("A gift's from label, note, and how many", .timeLimit(.minutes(2)))
@MainActor
struct GiftFieldsTests {
  typealias Route = NetworkConditioner.Route

  static let patchGift = Route("PATCH", "/gifts/{id}")

  let instance: Instance

  init() async throws {
    instance = try await Instance()
  }

  /// A giver with one open gift of `quantity` on an item of a person in their group, who wants `wanted`. A third
  /// person in the group can claim the rest.
  private struct Seeded {
    let giver: Fixture.Person
    let recipient: Fixture.Person
    let other: Fixture.Person
    let list: Fixture.List
    let gift: Fixture.Gift
  }

  private func seed(quantity: Int = 1, wanted: Int = 3) async throws -> Seeded {
    let builder = instance.builder
    let robin = try await builder.person("Robin")
    let morgan = try await builder.person("Morgan")
    let sam = try await builder.person("Sam")
    _ = try await builder.group("Family", users: [robin, morgan, sam])
    // Not the primary list, which no one else joins.
    let list = try await builder.list("Wishes", of: morgan)
    let kite = try await builder.item("Kite", on: list, as: morgan, quantity: wanted)
    let gift = try await builder.claim(kite, as: robin, quantity: quantity)
    return Seeded(giver: robin, recipient: morgan, other: sam, list: list, gift: gift)
  }

  /// A device of the instance, signed in as the person, with the gift in its copy.
  private func signedIn(
    as person: Fixture.Person, with gift: Fixture.Gift, diagnostics: any DiagnosticsReporter = .none
  ) async throws -> SessionModel {
    let device = instance.device(diagnostics: diagnostics)
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    await until { session.gift(id: gift.id) != nil }
    return session
  }

  /// The gift as the server has it for its giver.
  private func onServer(_ gift: Fixture.Gift) async throws -> JSON {
    try await gift.giver.signedIn().get("/gifts/\(gift.id)")
  }

  /// The bodies of the gift's patches that the instance saw, in order.
  private func patches(of gift: Fixture.Gift) throws -> [[String: Any]] {
    try instance.conditioner.requests
      .filter { $0.isOn(Self.patchGift) && $0.target.hasSuffix("/gifts/\(gift.id)") }
      .map { try JSONSerialization.jsonObject(with: $0.body) as? [String: Any] ?? [:] }
  }

  // MARK: - 1. The note and the from label

  @Test("The note and the from label are each saved as an unsent change, with only that field")
  func noteAndFromLabel() async throws {
    let seeded = try await seed()
    let session = try await signedIn(as: seeded.giver, with: seeded.gift)
    let id = seeded.gift.id

    // Offline, so each change waits in the journal and shows at once.
    instance.conditioner.dropEverything()
    await session.setFromLabel(gift: id, "  Emma  ")
    #expect(session.gift(id: id)?.fromLabel == "Emma")
    #expect(session.giftPage(id: id)?.gift.fromLabel == "Emma")
    #expect(session.giving.first { $0.id == id }?.fromLabel == "Emma")
    #expect(session.unsentChangeCount == 1)
    await session.setNote(gift: id, "The blue one, from the shop on Main St.")
    #expect(session.gift(id: id)?.note == .shown("The blue one, from the shop on Main St."))
    #expect(session.unsentChangeCount == 2)
    // The same text again is no change.
    await session.setFromLabel(gift: id, "Emma")
    #expect(session.unsentChangeCount == 2)

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    let server = try await onServer(seeded.gift)
    #expect(server["from_label"].string == "Emma")
    #expect(server["note"].string == "The blue one, from the shop on Main St.")
    let bodies = try patches(of: seeded.gift)
    #expect(bodies.map { $0.keys.sorted() } == [["from_label"], ["note"]])
    #expect(bodies.first?["from_label"] as? String == "Emma")

    // An empty field clears it, on the device at once and then on the server.
    await session.setNote(gift: id, "   ")
    #expect(session.gift(id: id)?.note == .shown(nil))
    await session.setFromLabel(gift: id, "")
    #expect(session.gift(id: id)?.fromLabel == nil)
    await until { session.unsentChangeCount == 0 }
    let cleared = try await onServer(seeded.gift)
    #expect(cleared["note"].string == nil)
    #expect(cleared["from_label"].string == nil)
    await until { session.gift(id: id)?.fromLabel == nil && session.gift(id: id)?.note == .shown(nil) }
  }

  // MARK: - 2. At most 60 characters

  @Test("A from label can't pass 60 characters, counted as the server counts them")
  func fromLabelLimit() async throws {
    // The server counts Unicode scalars. A character of several scalars goes whole, or not at all.
    let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
    #expect(GiftText.fromLabel(String(repeating: "x", count: 70)) == String(repeating: "x", count: 60))
    #expect(GiftText.fromLabel(String(repeating: "x", count: 58) + family) == String(repeating: "x", count: 58))
    #expect(GiftText.fromLabel(String(repeating: "é", count: 60)) == String(repeating: "é", count: 60))
    #expect(GiftText.fromLabel(" \n ") == nil)

    let seeded = try await seed()
    let session = try await signedIn(as: seeded.giver, with: seeded.gift)
    await session.setFromLabel(gift: seeded.gift.id, String(repeating: "é", count: 61))
    #expect(session.gift(id: seeded.gift.id)?.fromLabel == String(repeating: "é", count: 60))
    await until { session.unsentChangeCount == 0 }
    // The server took it: no late refusal.
    #expect(try await onServer(seeded.gift)["from_label"].string == String(repeating: "é", count: 60))
    #expect(session.lateRefusals.isEmpty)
  }

  // MARK: - 3. Lowering

  @Test("Lowering shows at once and is sent, also after it waited offline")
  func lowering() async throws {
    let seeded = try await seed(quantity: 3, wanted: 3)
    let session = try await signedIn(as: seeded.giver, with: seeded.gift)
    let id = seeded.gift.id
    #expect(session.gift(id: id)?.quantity == 3)

    await session.lowerQuantity(gift: id, to: 2)
    #expect(session.gift(id: id)?.quantity == 2)
    #expect(session.giftPage(id: id)?.gift.quantity == 2)
    await until { session.unsentChangeCount == 0 }
    #expect(try await onServer(seeded.gift)["quantity"].number == 2)

    // Offline: it shows at once, waits, and is sent when the network is back.
    instance.conditioner.dropEverything()
    await session.lowerQuantity(gift: id, to: 1)
    #expect(session.gift(id: id)?.quantity == 1)
    await until { session.isInstanceUnreachable }
    #expect(session.unsentChangeCount == 1)
    #expect(try await onServer(seeded.gift)["quantity"].number == 2)

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    #expect(try await onServer(seeded.gift)["quantity"].number == 1)
    #expect(session.gift(id: id)?.quantity == 1)
    #expect(try patches(of: seeded.gift).map { $0.keys.sorted() } == [["quantity"], ["quantity"]])

    // Not below one, and a lower that isn't lower is no change.
    await session.lowerQuantity(gift: id, to: 0)
    await session.lowerQuantity(gift: id, to: 1)
    #expect(session.unsentChangeCount == 0)
  }

  // MARK: - 4. Raising waits

  @Test("Raising waits for the server. After the answer, the copy has the new number")
  func raising() async throws {
    let seeded = try await seed(quantity: 1, wanted: 3)
    let session = try await signedIn(as: seeded.giver, with: seeded.gift)
    let id = seeded.gift.id
    #expect(session.gift(id: id)?.canRaiseQuantity == true)

    let answer = instance.conditioner.hold(Self.patchGift)
    let raise = Task { await session.raiseQuantity(gift: id) }
    await answer.waitUntilHeld()
    // The answer is held: the copy still has the old number, and nothing waits in the journal.
    #expect(session.gift(id: id)?.quantity == 1)
    #expect(session.unsentChangeCount == 0)
    answer.release()
    #expect(await raise.value == .raised)
    #expect(session.gift(id: id)?.quantity == 2)
    #expect(try await onServer(seeded.gift)["quantity"].number == 2)
    let body = try #require(try patches(of: seeded.gift).first)
    #expect(body.keys.sorted() == ["quantity"])
  }

  @Test("A raise after a lower that waits lands after it")
  func raiseAfterAWaitingLower() async throws {
    let seeded = try await seed(quantity: 3, wanted: 4)
    let session = try await signedIn(as: seeded.giver, with: seeded.gift)
    let id = seeded.gift.id

    // The lower waits, held at its request.
    let lowering = instance.conditioner.hold(Self.patchGift, at: .request)
    await session.lowerQuantity(gift: id, to: 1)
    await lowering.waitUntilHeld()
    #expect(session.gift(id: id)?.quantity == 1)
    let raise = Task { await session.raiseQuantity(gift: id) }
    lowering.release()

    let outcome = await raise.value
    #expect(outcome == .raised, "\(outcome)")
    #expect(session.gift(id: id)?.quantity == 2)
    #expect(try await onServer(seeded.gift)["quantity"].number == 2)
    #expect(try patches(of: seeded.gift).compactMap { $0["quantity"] as? Int } == [1, 2])
  }

  // MARK: - 5. Raising with no connection

  @Test("Raising with the network dropped changes nothing, and queues nothing")
  func raisingOffline() async throws {
    let seeded = try await seed(quantity: 1, wanted: 3)
    let session = try await signedIn(as: seeded.giver, with: seeded.gift)
    let id = seeded.gift.id

    instance.conditioner.dropEverything()
    #expect(await session.raiseQuantity(gift: id) == .unreachable)
    #expect(session.gift(id: id)?.quantity == 1)
    #expect(session.unsentChangeCount == 0)

    instance.conditioner.passEverything()
    await session.syncNow()
    #expect(session.unsentChangeCount == 0)
    #expect(try await onServer(seeded.gift)["quantity"].number == 1)
    #expect(session.gift(id: id)?.quantity == 1)
  }

  // MARK: - 6. Someone else got the rest

  @Test("A raise refused with item_fully_claimed says so, the number stays, and nothing is captured")
  func raiseFullyClaimed() async throws {
    let seeded = try await seed(quantity: 1, wanted: 2)
    let diagnostics = RecordingDiagnostics()
    let session = try await signedIn(as: seeded.giver, with: seeded.gift, diagnostics: diagnostics)
    let id = seeded.gift.id
    #expect(session.gift(id: id)?.canRaiseQuantity == true)

    // Someone else claims the last one. The giver's copy doesn't know yet.
    _ = try await instance.builder.claim(seeded.gift.item, as: seeded.other)

    #expect(await session.raiseQuantity(gift: id) == .someoneElseGotIt)
    #expect(session.gift(id: id)?.quantity == 1)
    #expect(session.unsentChangeCount == 0)
    #expect(try await onServer(seeded.gift)["quantity"].number == 1)
    #expect(diagnostics.faults.isEmpty)
  }

  // MARK: - 7. Now a recipient

  @Test("A giver who is now a recipient of the list can't raise")
  func recipientCantRaise() async throws {
    let seeded = try await seed(quantity: 2, wanted: 3)
    let diagnostics = RecordingDiagnostics()
    let session = try await signedIn(as: seeded.giver, with: seeded.gift, diagnostics: diagnostics)
    let id = seeded.gift.id
    #expect(session.gift(id: id)?.canRaiseQuantity == true)

    // The giver joins the list as a recipient. Their copy doesn't know yet: the server refuses the raise.
    let invitation = try await instance.builder.invite(seeded.giver, to: seeded.list, as: seeded.recipient)
    try await instance.builder.accept(invitation)
    let refused = await session.raiseQuantity(gift: id)
    guard case .refused(let refusal) = refused else {
      Issue.record("A recipient's raise ended \(refused)")
      return
    }
    #expect(refusal.code == .quantityRaiseNotAllowed)
    #expect(session.gift(id: id)?.quantity == 2)
    #expect(diagnostics.faults.isEmpty)

    // After a sync, the copy knows: no raise is offered, and none is sent. Lowering still works.
    await session.syncNow()
    await until { session.gift(id: id)?.canRaiseQuantity == false }
    let before = try patches(of: seeded.gift).count
    #expect(await session.raiseQuantity(gift: id) == .notOffered)
    #expect(try patches(of: seeded.gift).count == before)
    await session.lowerQuantity(gift: id, to: 1)
    await until { session.unsentChangeCount == 0 }
    #expect(try await onServer(seeded.gift)["quantity"].number == 1)
    #expect(session.lateRefusals.isEmpty)
  }
}
