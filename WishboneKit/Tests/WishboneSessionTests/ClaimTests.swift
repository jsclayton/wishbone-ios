import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// I'll get this: a claim of one, for the soonest occasion that the giver may pick, that waits for the server. Its
/// gift and the item's new numbers show at once, a claim after the last one says so, and with no connection nothing
/// is claimed. See "Claims are online only" in `docs/spec.md`, and `docs/screens/item.md`.
@Suite("I'll get this", .timeLimit(.minutes(1)))
@MainActor
struct ClaimTests {
  /// A device of the instance, signed in as the person. Its first sync has ended. The device's network goes
  /// through the instance's conditioner. Each device needs an instance of its own, because a second device with
  /// the same keychain stands for a relaunch of the first.
  private func signedIn(
    as person: Fixture.Person,
    on instance: Instance,
    diagnostics: any DiagnosticsReporter = .none
  ) async throws -> SessionModel {
    let device = instance.device(diagnostics: diagnostics)
    #expect(device.session == nil, "Each device of a test needs an instance of its own")
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    // A sign-in can end before the session publishes its last write.
    try await untilInStep(session, as: person)
    return session
  }

  /// The person's open gifts on the item, as the server has them.
  private func giftsOnServer(of person: Fixture.Person, onItem item: Fixture.Item) async throws -> [JSON] {
    let gifts = try await person.signedIn().get("/gifts?item_id=\(item.id)&giver_id=me&state=open")
    return gifts["data"].array ?? []
  }

  @Test("A claim makes an open gift of one on the server, and the copy has the gift and the new numbers at once")
  func claim() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.list("Wishes", of: family.child)
    let lamp = try await builder.item("Lamp", on: list, as: family.child, quantity: 2)
    let session = try await signedIn(as: family.relative, on: instance)
    #expect(try #require(session.itemPage(id: lamp.id)).offersClaim)

    #expect(await session.claim(item: lamp.id) == .claimed)

    // At once: no sync, and no wait for the copy's observation.
    let page = try #require(session.itemPage(id: lamp.id))
    #expect(page.claims.count == 1)
    #expect(page.claims.first?.quantity == 1)
    #expect(page.item.myClaimedQuantity == .shown(1))
    #expect(page.stillWanted == .count(1, of: 2))
    #expect(!page.offersClaim)
    let gift = try #require(session.giving.first { $0.itemID == lamp.id })
    #expect(page.claims.first?.id == gift.id)

    // The server has one open gift of one, for the soonest occasion that the giver may pick: the line names it.
    let onServer = try await giftsOnServer(of: family.relative, onItem: lamp)
    #expect(onServer.count == 1)
    #expect(onServer.first?["id"].string == gift.id)
    #expect(onServer.first?["quantity"].number == 1)
    let occasionName = try #require(onServer.first?["occasion_name"].string)
    #expect(page.claims.first?.occasion == .named(occasionName))
  }

  @Test("I'll get this is offered only from can_claim while the giver claimed none, and never to a recipient")
  func offered() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.list("Wishes", of: family.child)
    let lamp = try await builder.item("Lamp", on: list, as: family.child, quantity: 3)
    let scarf = try await builder.item("Scarf", on: list, as: family.child, quantity: 3)
    // The relative claimed one scarf elsewhere: two are still wanted, and the server still says can_claim.
    _ = try await builder.claim(scarf, as: family.relative, for: family.groupOccasion)

    let giver = try await signedIn(as: family.relative, on: instance)
    #expect(try #require(giver.itemPage(id: lamp.id)).offersClaim)
    #expect(giver.offersClaim(onItem: lamp.id))
    let claimedScarf = try #require(giver.itemPage(id: scarf.id))
    #expect(claimedScarf.item.canClaim)
    #expect(!claimedScarf.offersClaim)
    #expect(!giver.offersClaim(onItem: scarf.id))
    #expect(claimedScarf.claims.map(\.quantity) == [1])
    #expect(claimedScarf.claims.first?.occasion == .named(family.groupOccasion.name))

    // A recipient gets no button, no line, and no claim state.
    let recipientsInstance = try await Instance(server: instance.server)
    let recipient = try await signedIn(as: family.child, on: recipientsInstance)
    for item in [lamp, scarf] {
      let page = try #require(recipient.itemPage(id: item.id))
      #expect(!page.offersClaim)
      #expect(!recipient.offersClaim(onItem: item.id))
      #expect(page.claims.isEmpty)
    }
    // A claim that a recipient sends anyway gets the words for recipient_cannot_claim, and makes nothing.
    let refused = await recipient.claim(item: lamp.id)
    guard case .refused(let refusal) = refused else {
      Issue.record("A recipient's claim ended \(refused)")
      return
    }
    #expect(refusal.code == .recipientCannotClaim)
    #expect(recipient.gifts.isEmpty)
    #expect(!giver.offersClaim(onItem: "0"))
    // The recipient's device reaches the instance through this instance's conditioner, until here.
    withExtendedLifetime(recipientsInstance) {}
  }

  @Test("Two givers claim the last one: the second gets item_fully_claimed, no gift, and nothing captured")
  func someoneElseGotIt() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.list("Wishes", of: family.child)
    let lamp = try await builder.item("Lamp", on: list, as: family.child)
    let first = try await signedIn(as: family.relative, on: instance)
    let diagnostics = RecordingDiagnostics()
    let secondInstance = try await Instance(server: instance.server)
    let second = try await signedIn(as: family.parent, on: secondInstance, diagnostics: diagnostics)
    #expect(second.offersClaim(onItem: lamp.id))

    #expect(await first.claim(item: lamp.id) == .claimed)
    #expect(await second.claim(item: lamp.id) == .someoneElseGotIt)

    #expect(second.giving.isEmpty)
    #expect(try #require(second.itemPage(id: lamp.id)).claims.isEmpty)
    #expect(try await giftsOnServer(of: family.parent, onItem: lamp).isEmpty)
    #expect(try await giftsOnServer(of: family.relative, onItem: lamp).count == 1)
    // A refused claim is the server's answer to the person, and no fault.
    #expect(diagnostics.faults.isEmpty)

    // At the next sync, the item leaves the second giver's lists.
    await second.syncNow()
    await until { second.itemPage(id: lamp.id) == nil }
    // The second device reaches the instance through this instance's conditioner, until here.
    withExtendedLifetime(secondInstance) {}
  }

  @Test("With the network dropped, a claim says Can't reach, claims nothing, and leaves nothing to send")
  func unreachable() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.list("Wishes", of: family.child)
    let lamp = try await builder.item("Lamp", on: list, as: family.child)
    let session = try await signedIn(as: family.relative, on: instance)
    let before = try #require(session.itemPage(id: lamp.id))

    instance.conditioner.dropEverything()
    #expect(await session.claim(item: lamp.id) == .unreachable)
    #expect(session.itemPage(id: lamp.id) == before)
    #expect(session.giving.isEmpty)

    // When the network is back, a sync sends nothing: the claim was never an unsent change.
    instance.conditioner.passEverything()
    let seen = instance.conditioner.requests.count
    await session.syncNow()
    try await untilInStep(session, as: family.relative)
    #expect(instance.conditioner.requests.dropFirst(seen).allSatisfy { $0.method == "GET" })
    #expect(try await giftsOnServer(of: family.relative, onItem: lamp).isEmpty)
    #expect(try #require(session.itemPage(id: lamp.id)).offersClaim)
  }

  @Test("An answer that is lost, then a second tap: already_claimed is success, and the gift is in the copy")
  func lostAnswer() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.list("Wishes", of: family.child)
    let lamp = try await builder.item("Lamp", on: list, as: family.child, quantity: 2)
    let session = try await signedIn(as: family.relative, on: instance)

    // The server makes the gift, and its answer is lost on the way.
    let hold = instance.conditioner.hold(.init("POST", "/items/{id}/gifts"))
    let tap = Task { await session.claim(item: lamp.id) }
    await hold.waitUntilHeld()
    instance.conditioner.dropEverything()
    #expect(await tap.value == .unreachable)
    #expect(session.giving.isEmpty)

    instance.conditioner.passEverything()
    #expect(await session.claim(item: lamp.id) == .claimed)
    let page = try #require(session.itemPage(id: lamp.id))
    let onServer = try await giftsOnServer(of: family.relative, onItem: lamp)
    #expect(onServer.count == 1)
    #expect(page.claims.map(\.id) == onServer.compactMap { $0["id"].string })
    #expect(page.claims.first?.quantity == 1)
    #expect(page.item.myClaimedQuantity == .shown(1))
    #expect(!page.offersClaim)
  }

  @Test("A gift whose occasion the giver can't see gives its line with the reveal date, not the occasion")
  func hiddenOccasion() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let parent = try await builder.person("Morgan")
    let child = try await builder.person("Sam", parents: [parent])
    let list = try await builder.list("Wishes", of: child)
    let lamp = try await builder.item("Lamp", on: list, as: child)
    let session = try await signedIn(as: parent, on: instance)

    #expect(await session.claim(item: lamp.id) == .claimed)
    let gift = try #require(session.itemPage(id: lamp.id)?.claims.first)
    guard case .named = gift.occasion else {
      Issue.record("The line of a new claim names no occasion: \(gift.occasion)")
      return
    }
    // For gifts, no giver sees a deactivated recipient. The parent still sees the child's list, and their gift
    // shows only its reveal date.
    _ = try await builder.deactivate(child)
    await session.syncNow()
    await until {
      if case .hiddenUntil = session.itemPage(id: lamp.id)?.claims.first?.occasion { true } else { false }
    }
    let revealAt = try #require(session.gift(id: gift.id)?.revealAt)
    #expect(session.itemPage(id: lamp.id)?.claims.first?.occasion == .hiddenUntil(revealAt))
  }

  @Test("A parent who sees the list only through a deactivated child gets no I'll get this")
  func deactivatedRecipient() async throws {
    let instance = try await Instance()
    let family = try await instance.builder.standardFamily()
    let session = try await signedIn(as: family.parent, on: instance)

    let page = try #require(session.itemPage(id: family.wantedItem.id))
    #expect(!page.item.canClaim)
    #expect(!page.offersClaim)
    #expect(!session.offersClaim(onItem: family.wantedItem.id))
    // A claim sent anyway is refused with user_deactivated, and makes nothing.
    let refused = await session.claim(item: family.wantedItem.id)
    guard case .refused(let refusal) = refused else {
      Issue.record("The claim ended \(refused)")
      return
    }
    #expect(refusal.code == .userDeactivated)
    #expect(session.giving.isEmpty)
  }
}
