import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// Add again, at the session model's seam, against the real server: the form filled from a given gift, the list that
/// Add to starts on, and the add, a create that can wait, with `from_gift_id` and only the fields that the user
/// changed. The gift never changes. See `docs/screens/gift.md`, `docs/screens/gifts.md`, `docs/screens/add-form.md`,
/// "Unsent changes" in `docs/spec.md`, and "Add again" in the server's spec.
@Suite("Add again", .timeLimit(.minutes(2)))
@MainActor
final class AddAgainTests {
  typealias Route = NetworkConditioner.Route

  static let create = Route("POST", "/lists/{id}/items")

  let instance: Instance

  /// The one window of the app, as it comes to the foreground.
  let window = UUID()

  /// The instances of the devices that the test signed in on another instance of the same server.
  private var others: [Instance] = []

  init() async throws {
    instance = try await Instance()
  }

  /// A device signed in as the person, with the copy in step with the instance. With `onOwn`, the device goes
  /// through this test's own conditioner, which the test drops and holds. Otherwise the person signs in on another
  /// instance of the same server, because a device on the same one shares its session keychain.
  private func signedIn(
    as person: Fixture.Person, onOwn: Bool = false, storage: SessionStorage = .memory,
    diagnostics: any DiagnosticsReporter = .none
  ) async throws -> (Device, SessionModel) {
    let instance = onOwn ? self.instance : try await Instance(server: self.instance.server)
    if !onOwn { others.append(instance) }
    let device = instance.device(storage: storage, diagnostics: diagnostics)
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    try await untilInStep(session, as: person)
    return (device, session)
  }

  /// A kite, with a photo and a price, on the list, that the relative gave the child.
  private func givenKite(
    on list: Fixture.List, as editor: Fixture.Person, in family: StandardFamily
  ) async throws -> Fixture.Gift {
    let builder = instance.builder
    let kite = try await builder.item(
      "Kite \(builder.tag)", on: list, as: editor, imageIDs: [try await builder.image(as: editor)])
    try await editor.signedIn().send(
      "PATCH", "/items/\(kite.id)",
      json: ["price_minor": 2500, "top_price_minor": 3000, "currency": "USD"]
    ).expecting(200)
    let gift = try await builder.claim(kite, as: family.relative, for: family.groupOccasion)
    try await builder.reveal(giftsFor: family.child)
    return gift
  }

  /// An add that ended with the item added.
  private func added(_ outcome: AddOutcome, sourceLocation: SourceLocation = #_sourceLocation) throws -> AddedItem {
    guard case .added(let item) = outcome else {
      Issue.record("The add ended with \(outcome)", sourceLocation: sourceLocation)
      throw CancellationError()
    }
    return item
  }

  /// The items on the list with the title, as the person reads them on the server.
  private func onServer(_ title: String, on listID: String, as person: Fixture.Person) async throws -> [JSON] {
    try await person.signedIn().all("/lists/\(listID)/items").filter { $0["title"].string == title }
  }

  /// The bodies of the creates that the device sent, in order.
  private func createBodies() throws -> [[String: JSON]] {
    try instance.conditioner.requests.filter { $0.isOn(Self.create) }.map { request in
      guard case .object(let members) = try JSON(parsing: request.body) else { return [:] }
      return members
    }
  }

  // MARK: - 1. Offered from can_add_again, and filled from the gift

  @Test(
    """
    Add again shows only from can_add_again: for the recipient and their parent, never the giver. The form has the \
    gift's title, image and price
    """
  )
  func offered() async throws {
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let primary = try await builder.primaryList(of: family.child)
    let kite = try await givenKite(on: primary, as: family.child, in: family)
    let (_, child) = try await signedIn(as: family.child)
    let (_, parent) = try await signedIn(as: family.parent)
    let (_, giver) = try await signedIn(as: family.relative)

    let gift = try #require(child.gift(id: kite.id))
    #expect(gift.canAddAgain)
    #expect(try #require(child.givenGiftPage(id: kite.id)).offersAddAgain)
    let form = try #require(child.addAgainForm(gift: kite.id))
    #expect(form.isAddAgain)
    #expect(form.title == kite.item.title)
    #expect(form.title == gift.title)
    #expect(form.priceMinor == 2500)
    #expect(form.topPriceMinor == 3000)
    #expect(form.currency == "USD")
    let image = try #require(gift.image)
    #expect(form.gift?.image == image)
    #expect(form.keepsGiftImage)
    // Nothing else is filled in: no store link, no options, no notes, no note.
    #expect(form.storeLink == nil)
    #expect(form.images.isEmpty)
    #expect(form.photo == nil)
    #expect(form.notes.isEmpty)
    #expect(form.note == nil)

    // The child's parent sees the gift given to the child, and may add it again.
    #expect(try #require(parent.givenGiftPage(id: kite.id)).offersAddAgain)
    #expect(parent.addAgainForm(gift: kite.id)?.title == gift.title)

    // The giver sees the gift in Given, and is never offered Add again.
    #expect(giver.gift(id: kite.id)?.canAddAgain == false)
    #expect(try #require(giver.givenGiftPage(id: kite.id)).offersAddAgain == false)
    #expect(giver.addAgainForm(gift: kite.id) == nil)

    // An open gift is never added again: its giver has no form for it.
    let open = try await builder.claim(
      try await builder.item("Yo-yo \(builder.tag)", on: primary, as: family.child), as: family.relative,
      for: family.groupOccasion)
    #expect(await giver.syncNow() == .succeeded)
    try await untilInStep(giver, as: family.relative)
    #expect(giver.gift(id: open.id)?.state == .open)
    #expect(giver.addAgainForm(gift: open.id) == nil)
  }

  // MARK: - 2. The list Add to starts on

  @Test(
    """
    Add to starts on the gift's list when the user can still edit it, and otherwise on their own primary list
    """
  )
  func startingList() async throws {
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let camping = try await builder.list("Camping", of: family.child)
    let onCamping = try await givenKite(on: camping, as: family.child, in: family)
    // A list of the parent's that the child joined, then left after the reveal: the gift stays in Received.
    let lego = try await builder.list("Lego", of: family.parent)
    try await builder.accept(try await builder.invite(family.child, to: lego, as: family.parent))
    let onLego = try await givenKite(on: lego, as: family.parent, in: family)
    try await family.child.signedIn().send("DELETE", "/lists/\(lego.id)/recipients/\(family.child.id)")
      .expecting(204)
    let (_, child) = try await signedIn(as: family.child)
    let (_, parent) = try await signedIn(as: family.parent)

    // The gift's own list, which the child can edit, and which is not their primary list.
    #expect(child.list(id: camping.id)?.canEdit == true)
    let fromCamping = try #require(child.addAgainForm(gift: onCamping.id))
    #expect(fromCamping.listID == camping.id)
    #expect(child.target(of: fromCamping)?.list.id == camping.id)
    #expect(child.primaryList?.id != camping.id)

    // The child can no longer edit the gift's list, so the form starts on their own primary list.
    #expect(child.gift(id: onLego.id)?.canAddAgain == true)
    #expect(child.list(id: lego.id)?.canEdit != true)
    let fromLego = try #require(child.addAgainForm(gift: onLego.id))
    #expect(fromLego.listID == nil)
    #expect(child.target(of: fromLego)?.list.id == child.primaryList?.id)

    // The parent, a recipient of Lego, can still edit it, and of the child's list as their parent.
    #expect(parent.addAgainForm(gift: onLego.id)?.listID == lego.id)
    #expect(parent.addAgainForm(gift: onCamping.id)?.listID == camping.id)
  }

  @Test(
    """
    For a parent who can't edit the gift's list, Add to starts on the primary list of their child who received it
    """
  )
  func startingListOfTheChild() async throws {
    let builder = instance.builder
    let family = try await builder.standardFamily()
    // An uncle's list, which the child joined and left after the reveal. Nobody in the household can edit it then.
    let uncle = try await builder.person("Uncle")
    _ = try await builder.group("Kin", users: [family.relative, uncle], groups: [family.household])
    let tools = try await builder.list("Tools", of: uncle)
    try await builder.accept(try await builder.invite(family.child, to: tools, as: uncle))
    let hammer = try await builder.claim(
      try await builder.item("Hammer \(builder.tag)", on: tools, as: uncle), as: family.relative,
      for: family.groupOccasion)
    try await builder.reveal(giftsFor: family.child)
    try await family.child.signedIn().send("DELETE", "/lists/\(tools.id)/recipients/\(family.child.id)")
      .expecting(204)
    let childsPrimary = try await builder.primaryList(of: family.child)
    let (_, parent) = try await signedIn(as: family.parent)

    #expect(parent.gift(id: hammer.id)?.canAddAgain == true)
    #expect(parent.list(id: tools.id)?.canEdit != true)
    #expect(parent.primaryList?.id != childsPrimary.id)
    let form = try #require(parent.addAgainForm(gift: hammer.id))
    #expect(form.listID == childsPrimary.id)
    #expect(parent.target(of: form)?.list.id == childsPrimary.id)
  }

  // MARK: - 3. A copy of the image, and the gift as it was

  @Test("The new item has a copy of the gift's image and its price, and the gift is as it was, for everyone")
  func copiesAndKeepsTheGift() async throws {
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let primary = try await builder.primaryList(of: family.child)
    let kite = try await givenKite(on: primary, as: family.child, in: family)
    let (_, child) = try await signedIn(as: family.child, onOwn: true)
    let (_, giver) = try await signedIn(as: family.relative)
    let giftForChild = try await family.child.signedIn().get("/gifts/\(kite.id)")
    let giftForGiver = try await family.relative.signedIn().get("/gifts/\(kite.id)")
    let rowForChild = try #require(child.gift(id: kite.id))
    let rowForGiver = try #require(giver.gift(id: kite.id))
    let image = try #require(rowForChild.image)

    var form = try #require(child.addAgainForm(gift: kite.id))
    let item = try added(await child.add(&form))
    #expect(!StandIn.isStandIn(item.id))
    #expect(item.listName == child.primaryList?.name)

    // The server copied the title, the price, and the image as a new image of the item's own.
    let saved = try await onServer(kite.item.title, on: primary.id, as: family.child)
    #expect(saved.count == 1)
    let made = try #require(saved.first { $0["id"].string == item.id })
    #expect(made["price_minor"].number == 2500)
    #expect(made["top_price_minor"].number == 3000)
    #expect(made["currency"].string == "USD")
    let copy = try #require(made["primary_image"]["id"].string)
    #expect(copy != image.id)
    #expect(made["primary_image"]["url"].string != image.url)
    // The copy has the item's image, and the gift is in it as it was.
    let row = try #require(child.item(id: item.id))
    #expect(row.primaryImage?.id == copy)
    #expect(row.priceMinor == 2500)

    // The gift didn't change, on the server or in either copy, after a sync.
    #expect(try await family.child.signedIn().get("/gifts/\(kite.id)") == giftForChild)
    #expect(try await family.relative.signedIn().get("/gifts/\(kite.id)") == giftForGiver)
    #expect(await child.syncNow() == .succeeded)
    #expect(await giver.syncNow() == .succeeded)
    try await untilInStep(child, as: family.child)
    try await untilInStep(giver, as: family.relative)
    #expect(child.gift(id: kite.id) == rowForChild)
    #expect(giver.gift(id: kite.id) == rowForGiver)
    #expect(child.receivedGroups.flatMap(\.gifts).map(\.id).contains(kite.id))

    // The form sent the gift, and nothing that the server copies: the user changed nothing.
    let body = try #require(try createBodies().last)
    #expect(body["from_gift_id"]?.string == kite.id)
    #expect(Set(body.keys) == ["from_gift_id"])
  }

  @Test("In Add again's sheet, the duplicate hint is text: it never opens the item, as on the Add screen it does")
  func duplicateHintIsText() async throws {
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let primary = try await builder.primaryList(of: family.child)
    let kite = try await givenKite(on: primary, as: family.child, in: family)
    let (_, session) = try await signedIn(as: family.child)

    // The given item left the list at reveal, so the first Add again has no hint.
    var first = try #require(session.addAgainForm(gift: kite.id))
    #expect(session.duplicateHint(for: first) == nil)
    let item = try added(await session.add(&first))

    // A second Add again of the same gift finds the first one, and says so in words only.
    let second = try #require(session.addAgainForm(gift: kite.id))
    let hint = try #require(session.duplicateHint(for: second))
    #expect(hint.itemID == item.id)
    #expect(hint.title == kite.item.title)
    #expect(!hint.opensItem)

    // The same title typed on the Add screen gets a hint that opens the item.
    let typed = ItemDraft(given: .words(kite.item.title))
    #expect(session.duplicateHint(for: typed)?.opensItem == true)
  }

  // MARK: - 4. With the network dropped

  @Test(
    """
    An Add again made with the network dropped is on its list at once, with the gift's photo, and after a relaunch. \
    It is sent later, once
    """
  )
  func addedOffline() async throws {
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let primary = try await builder.primaryList(of: family.child)
    let kite = try await givenKite(on: primary, as: family.child, in: family)
    let folder = try ScratchDirectory("device")
    let standIn: String
    let image: ImageSummary
    do {
      // The device goes at the end of this scope, as the app does when it ends.
      let (_, session) = try await signedIn(as: family.child, onOwn: true, storage: .folder(folder.url))
      image = try #require(session.gift(id: kite.id)?.image)
      let gift = session.gift(id: kite.id)
      var form = try #require(session.addAgainForm(gift: kite.id))
      instance.conditioner.dropEverything()

      let item = try added(await session.add(&form))
      standIn = item.id
      #expect(StandIn.isStandIn(item.id))
      #expect(item.title == kite.item.title)
      // At once: at the end of the list, with the gift's photo and price, and the gift as it was.
      #expect(session.items(onList: primary.id).last?.id == item.id)
      let row = try #require(session.item(id: item.id))
      #expect(row.primaryImage == image)
      #expect(row.images == [image])
      #expect(row.priceMinor == 2500)
      #expect(row.topPriceMinor == 3000)
      #expect(session.gift(id: kite.id) == gift)
      #expect(session.unsentChangeCount == 1)
      await until { session.isInstanceUnreachable }
    }

    let relaunched = instance.device(storage: .folder(folder.url))
    let session = try #require(relaunched.session)
    // What is saved shows at once, the photo included.
    #expect(session.item(id: standIn)?.primaryImage == image)
    #expect(session.unsentChangeCount == 1)
    await session.syncNow()
    #expect(try await onServer(kite.item.title, on: primary.id, as: family.child).isEmpty)

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    let saved = try await onServer(kite.item.title, on: primary.id, as: family.child)
    #expect(saved.count == 1)
    let serverID = try #require(saved.first?["id"].string)
    let copy = try #require(saved.first?["primary_image"]["id"].string)
    #expect(copy != image.id)
    #expect(saved.first?["price_minor"].number == 2500)
    await until { session.items(onList: primary.id).last?.id == serverID }
    #expect(session.serverID(of: standIn) == serverID)
    #expect(session.item(id: serverID)?.primaryImage?.id == copy)
    // Sent once, with the gift, through the relaunch.
    await session.syncNow()
    let bodies = try createBodies()
    #expect(bodies.count == 1)
    #expect(bodies.first?["from_gift_id"]?.string == kite.id)
    #expect(try await onServer(kite.item.title, on: primary.id, as: family.child).count == 1)
  }

  @Test("An Add again whose answer is lost waits with the form's key, and the server makes one item")
  func lostAnswer() async throws {
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let primary = try await builder.primaryList(of: family.child)
    let kite = try await givenKite(on: primary, as: family.child, in: family)
    let (_, session) = try await signedIn(as: family.child, onOwn: true)
    let form = try #require(session.addAgainForm(gift: kite.id))

    // The server adds the item, and the answer is lost.
    let hold = instance.conditioner.hold(Self.create, at: .answer)
    let adding = Task {
      var form = form
      return await session.add(&form)
    }
    await hold.waitUntilHeld()
    instance.conditioner.dropEverything()
    let item = try added(await adding.value)
    #expect(StandIn.isStandIn(item.id))

    instance.conditioner.passEverything()
    await session.syncNow()
    await until { session.unsentChangeCount == 0 }
    let creates = instance.conditioner.requests.filter { $0.isOn(Self.create) }
    #expect(creates.count >= 2)
    #expect(Set(creates.compactMap { $0.headers["idempotency-key"] }).count == 1)
    #expect(try await onServer(kite.item.title, on: primary.id, as: family.child).count == 1)
    await until { session.items(onList: primary.id).count { $0.title == kite.item.title } == 1 }
  }

  // MARK: - 5. What the user changed wins

  @Test("A title changed in the form is the new item's title. Only the changed fields go beside the gift")
  func changedTitle() async throws {
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let primary = try await builder.primaryList(of: family.child)
    let kite = try await givenKite(on: primary, as: family.child, in: family)
    let (_, session) = try await signedIn(as: family.child, onOwn: true)
    let title = "A bigger kite \(builder.tag)"

    var form = try #require(session.addAgainForm(gift: kite.id))
    form.title = "  \(title) "
    let item = try added(await session.add(&form))
    #expect(item.title == title)

    let saved = try await onServer(title, on: primary.id, as: family.child)
    #expect(saved.count == 1)
    // The price and the image are still the gift's copy.
    #expect(saved.first?["price_minor"].number == 2500)
    #expect(!(saved.first?["primary_image"].isNull ?? true))
    #expect(session.item(id: item.id)?.title == title)
    let body = try #require(try createBodies().last)
    #expect(Set(body.keys) == ["from_gift_id", "title"])
    #expect(body["title"]?.string == title)
  }

  @Test("A cleared photo and a cleared price win over the copy: the item has neither, and the notes go too")
  func clearedPhotoAndPrice() async throws {
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let primary = try await builder.primaryList(of: family.child)
    let kite = try await givenKite(on: primary, as: family.child, in: family)
    let (_, session) = try await signedIn(as: family.child, onOwn: true)

    var form = try #require(session.addAgainForm(gift: kite.id))
    form.keepsGiftImage = false
    form.priceMinor = nil
    form.notes = "The red one"
    let item = try added(await session.add(&form))

    let saved = try await onServer(kite.item.title, on: primary.id, as: family.child)
    let made = try #require(saved.first { $0["id"].string == item.id })
    #expect(made["primary_image"].isNull)
    #expect(made["images"].array?.isEmpty ?? true)
    #expect(made["price_minor"].isNull)
    #expect(made["notes"].string == "The red one")
    let body = try #require(try createBodies().last)
    #expect(Set(body.keys) == ["from_gift_id", "notes", "price_minor", "image_ids"])
    #expect(body["price_minor"] == .null)
    #expect(body["image_ids"] == .array([]))
  }

  @Test("A changed price goes as a group: the item has the new price and no top price")
  func changedPrice() async throws {
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let primary = try await builder.primaryList(of: family.child)
    let kite = try await givenKite(on: primary, as: family.child, in: family)
    let (_, session) = try await signedIn(as: family.child, onOwn: true)

    var form = try #require(session.addAgainForm(gift: kite.id))
    form.priceMinor = 1800
    form.topPriceMinor = nil
    let item = try added(await session.add(&form))

    let saved = try await onServer(kite.item.title, on: primary.id, as: family.child)
    let made = try #require(saved.first { $0["id"].string == item.id })
    #expect(made["price_minor"].number == 1800)
    #expect(made["top_price_minor"].isNull)
    #expect(!made["primary_image"].isNull)
    let body = try #require(try createBodies().last)
    #expect(Set(body.keys) == ["from_gift_id", "price_minor", "currency"])
  }

  // MARK: - 6. A late refusal

  @Test(
    """
    An Add again that a parent made offline for their child, who is deactivated before it is sent, is refused \
    late: the item goes, the refusal shows once and is captured by its code, and the gift is as it was
    """
  )
  func refusedLate() async throws {
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let primary = try await builder.primaryList(of: family.child)
    let kite = try await givenKite(on: primary, as: family.child, in: family)
    let diagnostics = RecordingDiagnostics()
    let (_, parent) = try await signedIn(as: family.parent, onOwn: true, diagnostics: diagnostics)
    let gift = parent.gift(id: kite.id)
    var form = try #require(parent.addAgainForm(gift: kite.id))
    #expect(form.listID == primary.id)

    instance.conditioner.dropEverything()
    let item = try added(await parent.add(&form))
    #expect(parent.items(onList: primary.id).last?.id == item.id)
    await until { parent.isInstanceUnreachable }
    // Meanwhile, the admin deactivates the child.
    _ = try await builder.deactivate(family.child)

    instance.conditioner.passEverything()
    await parent.syncNow()
    await until { parent.unsentChangeCount == 0 }
    await until { parent.item(id: item.id) == nil }
    #expect(try await onServer(kite.item.title, on: primary.id, as: family.parent).isEmpty)
    #expect(diagnostics.faults == [.refusedWrite(.createItem, code: "user_deactivated")])
    // The gift is as it was. Only what the parent may do with it changed, with the deactivation: a deactivated
    // child's gifts offer no Add again.
    try await untilInStep(parent, as: family.parent)
    let after = try #require(parent.gift(id: kite.id))
    let before = try #require(gift)
    #expect(after.state == before.state)
    #expect(after.title == before.title)
    #expect(after.image == before.image)
    #expect(after.priceMinor == before.priceMinor)
    #expect(after.quantity == before.quantity)
    #expect(after.recipientIDs == before.recipientIDs)
    #expect(!after.canAddAgain)
    #expect(parent.addAgainForm(gift: kite.id) == nil)

    await parent.cameToForeground(window: window)
    let alert = try #require(parent.lateRefusalAlert)
    #expect(alert.refusals.count == 1)
    let refusal = try #require(alert.refusals.first)
    guard case .createItem(let created) = refusal.action else {
      Issue.record("The refusal was of \(refusal.action)")
      return
    }
    #expect(created.id == item.id)
    #expect(created.fromGift?.giftID == kite.id)
    #expect(refusal.title == kite.item.title)
    #expect(refusal.refusal.code == .userDeactivated)
    parent.lateRefusalsShown(in: window)
    parent.leftForeground(window: window)
    await parent.cameToForeground(window: window)
    #expect(parent.lateRefusalAlert == nil)
  }
}
