import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// The lists: after sign-in, the copy holds every list that the session's user can see, with its items, their
/// store links, and its recipient rows, and every pending invitation that the user can see. A sync keeps them
/// current. See "What the copy holds" in `docs/spec.md`.
@Suite(
  "After sign-in, every list is in the copy, with its items, store links, recipients and invitations",
  .timeLimit(.minutes(2)))
@MainActor
struct ListsTests {
  typealias Route = NetworkConditioner.Route

  /// The time zone of every device of this suite, and of every user who signs in.
  static let zone = "Europe/Paris"

  /// The kinds of entry that the copy holds for the lists.
  static let kinds: Set<String> = ["list", "list_recipient", "item", "store_link", "invitation"]

  /// The kinds of entry that the copy holds for Home.
  static let homeKinds: Set<String> = [
    "user", "user_summary", "group", "occasion", "group_users", "users_in_group", "users_of_occasion",
    "group_groups", "occasion_groups",
  ]

  /// Each test has a server of its own. So the versions that the instance names are the ones of this test's own
  /// family, and nothing changes them but the test.
  let server: TestServer
  let builder: FixtureBuilder

  init() async throws {
    server = try await TestServer.start()
    builder = try await FixtureBuilder(server: server)
  }

  // MARK: - Devices

  /// One person's device: the session model, and the conditioner that its requests go through.
  struct Signed {
    let person: Fixture.Person
    let instance: Instance
    let device: Device
    let session: SessionModel

    /// How many requests the device has made. The requests after this mark are those of what the test does next.
    var mark: Int {
      instance.conditioner.requests.count
    }

    /// What the device asked of the instance after the mark, oldest first, such as `GET /items/12`: the method,
    /// and the path under `/api/v2` with any query.
    func asked(since mark: Int = 0) -> [String] {
      instance.conditioner.requests.dropFirst(mark).map {
        "\($0.method) \($0.target.dropFirst(TestServer.apiPrefix.count))"
      }
    }
  }

  /// Gives the user's record the zone of this suite's devices. So a sign-in reports none, and nothing changes the
  /// user after the first sync but what the test does.
  private func setZone(of people: Fixture.Person...) async throws {
    for person in people {
      try await person.signedIn().send("PATCH", "/users/me", json: ["timezone": .string(Self.zone)]).expecting(200)
    }
  }

  /// Signs the person in on a new device, with a conditioner and a keychain of its own. The first sync has ended
  /// when it returns.
  private func signedIn(
    as person: Fixture.Person,
    storage: SessionStorage = .memory
  ) async throws -> Signed {
    try await setZone(of: person)
    let instance = try await Instance(server: server)
    let device = instance.device(storage: storage, timeZone: .fixed(Self.zone))
    await device.signIn(pasting: try await instance.loginLink(for: person))
    return Signed(person: person, instance: instance, device: device, session: try #require(device.session))
  }

  // MARK: - The copy, and the instance's own answers

  /// The items of every list in the copy.
  private func items(of session: SessionModel) -> [ItemRow] {
    session.lists.flatMap { session.items(onList: $0.id) }
  }

  /// What the copy holds, as the entries of `GET /versions` are: `kind id version`. A recipient row is named by
  /// its list and its user, an item by its list too, and a store link by its item too.
  private func entries(of session: SessionModel) -> Set<String> {
    var entries: Set<String> = []
    for list in session.lists {
      entries.insert("list \(list.id) \(list.version)")
      for row in session.recipients(ofList: list.id) {
        entries.insert("list_recipient \(row.listID)/\(row.userID) \(row.version)")
      }
    }
    for item in items(of: session) {
      entries.insert("item \(item.listID)/\(item.id) \(item.version)")
      for link in session.storeLinks(ofItem: item.id) {
        entries.insert("store_link \(link.itemID)/\(link.id) \(link.version)")
      }
    }
    for invitation in session.invitations {
      entries.insert("invitation \(invitation.id) \(invitation.version)")
    }
    for user in session.users {
      entries.insert("\(user.isSummary ? "user_summary" : "user") \(user.id) \(user.version)")
    }
    for group in session.groups {
      entries.insert("group \(group.id) \(group.version)")
    }
    for occasion in session.occasions {
      entries.insert("occasion \(occasion.id) \(occasion.version)")
    }
    for membership in session.memberships {
      entries.insert("\(membership.kind.rawValue) \(membership.ownerID) \(membership.version)")
    }
    return entries
  }

  /// What the instance names for the person now, for every kind that the copy holds. The person's own session
  /// asks, not the device.
  private func entries(namedFor person: Fixture.Person) async throws -> Set<String> {
    entries(in: try await person.signedIn().get("/versions")["data"].array ?? [])
  }

  /// The entries of an answer of `GET /versions`, for every kind that the copy holds, named as `entries(of:)`
  /// names the copy's.
  private func entries(in data: [JSON]) -> Set<String> {
    Set(
      data.compactMap { entry in
        guard let kind = entry["kind"].string, Self.kinds.union(Self.homeKinds).contains(kind) else { return nil }
        let id = entry["id"].string ?? ""
        let version = entry["version"].string ?? ""
        switch kind {
        case "list_recipient", "item": return "\(kind) \(entry["list_id"].string ?? "")/\(id) \(version)"
        case "store_link": return "\(kind) \(entry["item_id"].string ?? "")/\(id) \(version)"
        default: return "\(kind) \(id) \(version)"
        }
      })
  }

  /// Waits until the copy holds what the instance names for the person, each thing with its version.
  private func inStep(_ signed: Signed, _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation)
    async throws
  {
    let named = try await entries(namedFor: signed.person)
    await until { entries(of: signed.session) == named }
    #expect(entries(of: signed.session) == named, comment, sourceLocation: sourceLocation)
  }

  /// The kinds of the copy's entries, for the kinds of the lists.
  private func kinds(of session: SessionModel) -> Set<String> {
    Set(entries(of: session).compactMap { $0.split(separator: " ").first.map(String.init) }).intersection(Self.kinds)
  }

  /// Checks each list, recipient row, item, store link and invitation of the copy against the instance's own
  /// answer, as the device's person reads it.
  private func expectEveryField(of signed: Signed, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let own = try signed.person.signedIn()
    func expect(_ condition: Bool, _ what: String) {
      #expect(condition, "\(what)", sourceLocation: sourceLocation)
    }
    func text(_ date: Date?) -> String? {
      date?.formatted(.iso8601)
    }
    func number(_ value: Int?) -> Double? {
      value.map(Double.init)
    }
    /// A field that the server can hide: hidden when the key is absent.
    func hideable(_ json: JSON, _ key: String) -> Hideable<Double> {
      guard case .object(let members) = json, let value = members[key] else { return .hidden }
      return .shown(value.number)
    }
    func hideable(_ value: Hideable<Int>) -> Hideable<Double> {
      switch value {
      case .hidden: .hidden
      case .shown(let value): .shown(value.map(Double.init))
      }
    }

    for list in signed.session.lists {
      let answer = try await own.send("GET", "/lists/\(list.id)").expecting(200)
      let json = try answer.json
      let what = "list \(list.id)"
      expect(list.version == answer.headers["etag"], "\(what): version")
      expect(list.name == json["name"].string, "\(what): name")
      expect(list.description == json["description"].string, "\(what): description")
      expect(list.isPrimary == json["is_primary"].bool, "\(what): is_primary")
      expect(
        list.recipientIDs == (json["recipients"].array ?? []).compactMap { $0["id"].string }, "\(what): recipients")
      expect(number(list.itemCount) == json["item_count"].number, "\(what): item_count")
      expect(text(list.createdAt) == json["created_at"].string, "\(what): created_at")
      expect(list.canEdit == json["can_edit"].bool, "\(what): can_edit")
      expect(list.canDelete == json["can_delete"].bool, "\(what): can_delete")
      expect(list.canInvite == json["can_invite"].bool, "\(what): can_invite")
      expect(list.canLeave == json["can_leave"].bool, "\(what): can_leave")

      let recipients = try await own.all("/lists/\(list.id)/recipients")
      let rows = signed.session.recipients(ofList: list.id)
      expect(rows.map(\.userID) == recipients.compactMap { $0["user"]["id"].string }, "\(what): recipient rows")
      for (row, json) in zip(rows, recipients) {
        let what = "recipient \(list.id)/\(row.userID)"
        expect(row.version == json["version"].string, "\(what): version")
        expect(text(row.createdAt) == json["created_at"].string, "\(what): created_at")
        let sees: Hideable<Bool> =
          if case .object(let members) = json, let value = members["sees_list_after_leaving"] {
            .shown(value.bool)
          } else {
            .hidden
          }
        expect(row.seesListAfterLeaving == sees, "\(what): sees_list_after_leaving")
        expect(row.canDelete == json["can_delete"].bool, "\(what): can_delete")
      }
    }

    for item in items(of: signed.session) {
      let answer = try await own.send("GET", "/items/\(item.id)").expecting(200)
      let json = try answer.json
      let what = "item \(item.id)"
      expect(item.version == answer.headers["etag"], "\(what): version")
      expect(item.listID == json["list_id"].string, "\(what): list_id")
      expect(item.title == json["title"].string, "\(what): title")
      expect(item.notes == json["notes"].string, "\(what): notes")
      expect(number(item.priceMinor) == json["price_minor"].number, "\(what): price_minor")
      expect(number(item.topPriceMinor) == json["top_price_minor"].number, "\(what): top_price_minor")
      expect(item.currency == json["currency"].string, "\(what): currency")
      expect(number(item.quantity) == json["quantity"].number, "\(what): quantity")
      expect(item.isUnlimited == json["is_unlimited"].bool, "\(what): is_unlimited")
      expect(number(item.position) == json["position"].number, "\(what): position")
      expect(item.addedByID == json["added_by"]["id"].string, "\(what): added_by")
      expect(text(item.createdAt) == json["created_at"].string, "\(what): created_at")
      expect(item.images.map(\.id) == (json["images"].array ?? []).compactMap { $0["id"].string }, "\(what): images")
      expect(item.primaryImage?.id == json["primary_image"]["id"].string, "\(what): primary_image")
      expect(hideable(item.stillWanted) == hideable(json, "still_wanted"), "\(what): still_wanted")
      expect(
        hideable(item.myClaimedQuantity) == hideable(json, "my_claimed_quantity"), "\(what): my_claimed_quantity")
      expect(item.canEdit == json["can_edit"].bool, "\(what): can_edit")
      expect(item.canDelete == json["can_delete"].bool, "\(what): can_delete")
      expect(item.canClaim == json["can_claim"].bool, "\(what): can_claim")
      expect(item.canRefreshPrices == json["can_refresh_prices"].bool, "\(what): can_refresh_prices")

      let links = signed.session.storeLinks(ofItem: item.id)
      let bodies = json["store_links"].array ?? []
      expect(links.map(\.id) == bodies.compactMap { $0["id"].string }, "\(what): store links, in order")
      for (link, json) in zip(links, bodies) {
        let what = "store link \(link.id)"
        expect(link.url == json["url"].string, "\(what): url")
        expect(link.store == json["store"].string, "\(what): store")
        expect(number(link.priceMinor) == json["price_minor"].number, "\(what): price_minor")
        expect(link.currency == json["currency"].string, "\(what): currency")
        expect(text(link.capturedAt) == json["captured_at"].string, "\(what): captured_at")
        expect(link.imageURL == json["image_url"].string, "\(what): image_url")
        expect(text(link.createdAt) == json["created_at"].string, "\(what): created_at")
        expect(link.canEdit == json["can_edit"].bool, "\(what): can_edit")
        expect(link.canDelete == json["can_delete"].bool, "\(what): can_delete")
      }
    }

    for invitation in signed.session.invitations {
      let answer = try await own.send("GET", "/invitations/\(invitation.id)").expecting(200)
      let json = try answer.json
      let what = "invitation \(invitation.id)"
      expect(invitation.version == answer.headers["etag"], "\(what): version")
      expect(invitation.listID == json["list"]["id"].string, "\(what): list.id")
      expect(invitation.listName == json["list"]["name"].string, "\(what): list.name")
      expect(invitation.userID == json["user"]["id"].string, "\(what): user")
      expect(invitation.invitedByID == json["invited_by"]["id"].string, "\(what): invited_by")
      expect(text(invitation.createdAt) == json["created_at"].string, "\(what): created_at")
      expect(invitation.canAccept == json["can_accept"].bool, "\(what): can_accept")
      expect(invitation.canDelete == json["can_delete"].bool, "\(what): can_delete")
    }
  }

  // MARK: - 1. What the copy holds

  @Test(
    """
    For each person of the family, the copy holds the lists, recipient rows, items, store links and invitations \
    that the instance names, each with its version and every field that its viewer gets
    """
  )
  func everyPersonsCopy() async throws {
    let family = try await builder.standardFamily()
    let parentsList = try await builder.primaryList(of: family.parent)
    _ = try await builder.item(
      "Scarf", on: parentsList, as: family.parent,
      storeLinks: [("https://shop.example/scarf", 2500), ("https://other.example/scarf", nil)])
    let people = [
      ("the admin", family.admin), ("the parent", family.parent), ("the child", family.child),
      ("the relative", family.relative), ("the outsider", family.outsider),
    ]
    try await setZone(of: family.admin, family.parent, family.child, family.relative, family.outsider)

    var held: [String: Set<String>] = [:]
    for (role, person) in people {
      let signed = try await signedIn(as: person)
      try await inStep(signed, "\(role)")
      try await expectEveryField(of: signed)
      held[role] = kinds(of: signed.session)
    }

    // Each case that the family is for is in one copy at least. The parent sees the deactivated child's pending
    // invitation, as their parent and as a recipient of the list.
    #expect(held["the parent"] == Self.kinds)
    #expect(held["the relative"] == Self.kinds.subtracting(["invitation"]))
    #expect(held["the child"] == Self.kinds.subtracting(["invitation"]))
    // The outsider and the admin see only their own primary list, which has no item.
    #expect(held["the outsider"] == ["list", "list_recipient"])
    #expect(held["the admin"] == ["list", "list_recipient"])
  }

  // MARK: - 2. Claim state

  @Test(
    """
    A recipient's copy of their own items has no claim state, and a giver's has it. When someone else claims the \
    last one, the item leaves that giver's copy at the next sync
    """
  )
  func claimState() async throws {
    let family = try await builder.standardFamily()
    let childsList = try await builder.primaryList(of: family.child)
    let kite = try await builder.item("Kite", on: childsList, as: family.child)

    // The child is the recipient. The server never sends them the claim state of their own items.
    let child = try await signedIn(as: family.child)
    try await inStep(child)
    let own = try #require(child.session.item(id: kite.id))
    #expect(own.stillWanted == .hidden)
    #expect(own.myClaimedQuantity == .hidden)
    #expect(!own.canClaim)

    // The parent and the relative are givers.
    let parent = try await signedIn(as: family.parent)
    try await inStep(parent)
    let given = try #require(parent.session.item(id: kite.id))
    #expect(given.stillWanted == .shown(1))
    #expect(!given.myClaimedQuantity.isHidden)
    #expect(given.canClaim)
    try await expectEveryField(of: parent)

    // The relative claims the last one. The parent no longer sees the item, and the relative still does, with
    // their own gift on it.
    _ = try await builder.claim(kite, as: family.relative, for: family.groupOccasion)
    #expect(try await family.parent.signedIn().status(of: "/items/\(kite.id)") == 404)
    await parent.session.syncNow()
    try await inStep(parent)
    #expect(parent.session.item(id: kite.id) == nil)
    #expect(parent.session.list(id: childsList.id)?.itemCount == 0)

    let relative = try await signedIn(as: family.relative)
    try await inStep(relative)
    let claimed = try #require(relative.session.item(id: kite.id))
    #expect(claimed.stillWanted == .shown(0))
    #expect(claimed.myClaimedQuantity == .shown(1))
    #expect(!claimed.canClaim)

    // The recipient's copy still has no claim state, and the item stays.
    await child.session.syncNow()
    try await inStep(child)
    #expect(child.session.item(id: kite.id)?.stillWanted == .hidden)
    #expect(child.session.item(id: kite.id)?.myClaimedQuantity == .hidden)
  }

  // MARK: - 3. Recipient rows

  @Test(
    """
    A recipient row has sees_list_after_leaving only for that user and their parents, and its can_delete, as the \
    server gives each of them
    """
  )
  func recipientRows() async throws {
    let family = try await builder.standardFamily()
    let shared = family.sharedList.id
    func row(_ person: Fixture.Person, in signed: Signed) throws -> RecipientRow {
      try #require(signed.session.recipients(ofList: shared).first { $0.userID == person.id })
    }

    // The child sees only their own.
    let child = try await signedIn(as: family.child)
    try await inStep(child)
    #expect(child.session.recipients(ofList: shared).map(\.userID) == [family.deactivatedChild.id, family.child.id])
    #expect(try row(family.child, in: child).seesListAfterLeaving.isHidden == false)
    #expect(try row(family.deactivatedChild, in: child).seesListAfterLeaving == .hidden)
    #expect(try row(family.child, in: child).canDelete)
    #expect(try !row(family.deactivatedChild, in: child).canDelete)

    // The parent sees both, as the parent of both. A deactivated child can't be made to leave.
    let parent = try await signedIn(as: family.parent)
    try await inStep(parent)
    #expect(try row(family.child, in: parent).seesListAfterLeaving.isHidden == false)
    #expect(try row(family.deactivatedChild, in: parent).seesListAfterLeaving.isHidden == false)
    #expect(try row(family.child, in: parent).canDelete)
    #expect(try !row(family.deactivatedChild, in: parent).canDelete)

    // The relative sees the list through the child, and gets neither.
    let relative = try await signedIn(as: family.relative)
    try await inStep(relative)
    #expect(try row(family.child, in: relative).seesListAfterLeaving == .hidden)
    #expect(try row(family.deactivatedChild, in: relative).seesListAfterLeaving == .hidden)
    #expect(try !row(family.child, in: relative).canDelete)
    #expect(try !row(family.deactivatedChild, in: relative).canDelete)

    // Each value is the server's own.
    for signed in [child, parent, relative] {
      let answer = try await signed.person.signedIn().all("/lists/\(shared)/recipients")
      for json in answer {
        let id = try #require(json["user"]["id"].string)
        let held = try #require(signed.session.recipients(ofList: shared).first { $0.userID == id })
        #expect(held.seesListAfterLeaving.value == json["sees_list_after_leaving"].bool)
        #expect(held.canDelete == json["can_delete"].bool)
      }
    }
  }

  // MARK: - 4. A deactivated child

  @Test("A parent holds a deactivated child's lists and their items, with can_edit false")
  func deactivatedChildsLists() async throws {
    let family = try await builder.standardFamily()
    let parent = try await signedIn(as: family.parent)
    try await inStep(parent)
    let session = parent.session

    for list in [family.primaryList, family.extraList] {
      let row = try #require(session.list(id: list.id), "\(list.name)")
      #expect(!row.canEdit, "\(list.name)")
      #expect(!row.canDelete, "\(list.name)")
      #expect(row.recipientIDs == [family.deactivatedChild.id], "\(list.name)")
      #expect(!session.items(onList: list.id).isEmpty, "\(list.name)")
      #expect(session.items(onList: list.id).allSatisfy { !$0.canEdit && !$0.canDelete }, "\(list.name)")
    }
    #expect(session.items(onList: family.primaryList.id).map(\.id) == [family.wantedItem.id])
    // The list shared with the active child stays editable, through that child.
    #expect(session.list(id: family.sharedList.id)?.canEdit == true)
    // The deactivated child is held in full, as their parent sees them.
    #expect(session.user(id: family.deactivatedChild.id)?.isSummary == false)
  }

  // MARK: - 5. Store links

  @Test(
    """
    Store links are held from the item's body, in the server's order for each viewer. A price that changes \
    elsewhere arrives with the item, and no store link route is called
    """
  )
  func storeLinks() async throws {
    let family = try await builder.standardFamily()
    let childsList = try await builder.primaryList(of: family.child)
    let links: [(url: String, priceMinor: Int?)] = [
      ("https://dear.example/bike", 30000), ("https://cheap.example/bike", 10000), ("https://none.example/bike", nil),
    ]
    let bike = try await builder.item("Bike", on: childsList, as: family.child, storeLinks: links)

    // The child can edit the list, so they get the links in the order added. A giver gets them by price, the
    // unpriced last.
    let child = try await signedIn(as: family.child)
    try await inStep(child)
    #expect(
      child.session.storeLinks(ofItem: bike.id).map(\.store) == ["dear.example", "cheap.example", "none.example"])
    let relative = try await signedIn(as: family.relative)
    try await inStep(relative)
    let held = relative.session.storeLinks(ofItem: bike.id)
    #expect(held.map(\.store) == ["cheap.example", "dear.example", "none.example"])
    #expect(held.map(\.priceMinor) == [10000, 30000, nil])
    #expect(held.map(\.currency) == ["USD", "USD", nil])
    #expect(held.allSatisfy { !$0.canEdit && !$0.canDelete && $0.itemID == bike.id })
    #expect(!relative.asked().contains { $0.contains("/store-links") })

    // The child lowers the dear one's price below the cheap one's. For the relative, the dear one comes first.
    let dear = try #require(held.first { $0.store == "dear.example" })
    try await family.child.signedIn().send(
      "PATCH", "/items/\(bike.id)/store-links/\(dear.id)", json: ["price_minor": 5000, "currency": "USD"]
    ).expecting(200)
    let mark = relative.mark
    await relative.session.syncNow()
    try await inStep(relative)
    #expect(relative.asked(since: mark) == ["GET /versions", "GET /items/\(bike.id)"])
    #expect(
      relative.session.storeLinks(ofItem: bike.id).map(\.store) == ["dear.example", "cheap.example", "none.example"])
    #expect(relative.session.storeLinks(ofItem: bike.id).first?.priceMinor == 5000)
    #expect(relative.session.storeLinks(ofItem: bike.id).first?.capturedAt != nil)
    try await expectEveryField(of: relative)

    // The copy agrees with the answer, so the next sync is one request, answered 304.
    let next = relative.mark
    await relative.session.syncNow()
    #expect(relative.asked(since: next) == ["GET /versions"])
    #expect(relative.instance.conditioner.requests.last?.headers["if-none-match"] != nil)
  }

  @Test(
    """
    A store link that changes while its item is on its way is saved with no version. The next sync reads the \
    item again, and then the copy agrees with the instance
    """
  )
  func storeLinkChangesDuringThePull() async throws {
    let family = try await builder.standardFamily()
    let childsList = try await builder.primaryList(of: family.child)
    let bike = try await builder.item(
      "Bike", on: childsList, as: family.child, storeLinks: [("https://shop.example/bike", 10000)])
    let relative = try await signedIn(as: family.relative)
    try await inStep(relative)
    let session = relative.session
    let link = try #require(session.storeLinks(ofItem: bike.id).first)
    let own = try family.child.signedIn()

    // The item changes, so the pull fetches it. The link's price changes while that fetch is on its way.
    try await own.send("PATCH", "/items/\(bike.id)", json: ["title": "Red bike"]).expecting(200)
    let hold = relative.instance.conditioner.hold(Route("GET", "/items/{id}"), at: .request)
    async let syncing = session.syncNow()
    await hold.waitUntilHeld()
    try await own.send("PATCH", "/items/\(bike.id)/store-links/\(link.id)", json: ["price_minor": 9000]).expecting(200)
    hold.release()
    _ = await syncing
    await until { session.storeLinks(ofItem: bike.id).first?.priceMinor == 9000 }

    // The item arrived as new as the answer that comes next. Its store link is not, so the item is read again.
    var mark = relative.mark
    await session.syncNow()
    try await inStep(relative)
    #expect(relative.asked(since: mark) == ["GET /versions", "GET /items/\(bike.id)"])

    mark = relative.mark
    await session.syncNow()
    #expect(relative.asked(since: mark) == ["GET /versions"])
    #expect(relative.instance.conditioner.requests.last?.headers["if-none-match"] != nil)
  }

  // MARK: - 6. The user's own lists first

  @Test("On the first sync, the items of the user's own lists are asked for before anyone else's, and after Home's")
  func ownListsFirst() async throws {
    let family = try await builder.standardFamily()
    let parentsList = try await builder.primaryList(of: family.parent)
    _ = try await builder.item("Scarf", on: parentsList, as: family.parent)
    _ = try await builder.item("Chair", on: family.parentList, as: family.parent)
    _ = try await builder.item("Lamp", on: family.parentList, as: family.parent)

    let parent = try await signedIn(as: family.parent)
    try await inStep(parent)
    let session = parent.session
    let own = Set(session.yourLists.map(\.id))
    #expect(own == [parentsList.id, family.parentList.id])
    #expect(session.yourLists.first?.id == parentsList.id)

    // Each request for items, by the list of its items.
    var listOfItem: [String: String] = [:]
    for item in items(of: session) {
      listOfItem[item.id] = item.listID
    }
    let asked = parent.asked()
    let forItems: [(index: Int, listID: String)] = asked.enumerated().compactMap { index, request in
      let parts = request.split(separator: "?")[0].split(separator: "/").map(String.init)
      if parts.count == 4, parts[1] == "lists", parts[3] == "items" { return (index, parts[2]) }
      if parts.count == 3, parts[1] == "items" { return listOfItem[parts[2]].map { (index, $0) } }
      return nil
    }
    let ownIndexes = forItems.filter { own.contains($0.listID) }.map(\.index)
    let othersIndexes = forItems.filter { !own.contains($0.listID) }.map(\.index)
    #expect(Set(forItems.filter { own.contains($0.listID) }.map(\.listID)) == own)
    #expect(!othersIndexes.isEmpty)
    #expect(try #require(ownIndexes.max()) < (try #require(othersIndexes.min())))
    // The primary list's items come first of all.
    #expect(forItems.first?.listID == parentsList.id)

    // Home's data came before any list's.
    let lastOfHome = try #require(asked.lastIndex { $0.hasPrefix("GET /users") || $0.hasPrefix("GET /groups") })
    let firstOfLists = try #require(
      asked.firstIndex { $0.hasPrefix("GET /lists") || $0.hasPrefix("GET /items") || $0.hasPrefix("GET /invitations") })
    #expect(lastOfHome < firstOfLists)
  }

  @Test(
    """
    With the requests for everyone else's lists held, the user's own lists already read from the copy, with their \
    items, and the sidebar's lists have them
    """
  )
  func ownListsReadFirst() async throws {
    let family = try await builder.standardFamily()
    let parentsList = try await builder.primaryList(of: family.parent)
    // Two items on each of the parent's own lists, so that the pull reads each list's items, and asks for no item
    // from its own address.
    var own: Set<String> = []
    for (title, list) in [
      ("Scarf", parentsList), ("Hat", parentsList), ("Chair", family.parentList), ("Lamp", family.parentList),
    ] {
      own.insert(try await builder.item(title, on: list, as: family.parent).id)
    }
    try await setZone(of: family.parent)
    let instance = try await Instance(server: server)
    let device = instance.device(timeZone: .fixed(Self.zone))
    let link = try await instance.loginLink(for: family.parent)

    // Everyone else's lists have one item each, which is asked for from its own address. No such request reaches
    // the instance.
    let hold = instance.conditioner.hold(Route("GET", "/items/{id}"), at: .request)
    async let signingIn: Void = device.signIn(pasting: link)
    await hold.waitUntilHeld()
    let held = try #require(instance.conditioner.requests.last?.target)
    #expect(held.hasPrefix(TestServer.apiPrefix + "/items/"))
    #expect(!own.contains { held.hasSuffix("/items/\($0)") })

    let session = try #require(device.session)
    await until { session.yourLists.count == 2 }
    #expect(session.yourLists.map(\.id) == [parentsList.id, family.parentList.id])
    #expect(session.items(onList: parentsList.id).map(\.title) == ["Scarf", "Hat"])
    #expect(session.items(onList: family.parentList.id).map(\.title) == ["Chair", "Lamp"])
    #expect(session.recipients(ofList: family.parentList.id).map(\.userID) == [family.parent.id])
    // Everyone else's lists are not in the copy yet.
    #expect(session.list(id: family.primaryList.id) == nil)
    #expect(session.list(id: family.sharedList.id) == nil)

    hold.release()
    await signingIn
    await until { session.items(onList: family.primaryList.id).map(\.id) == [family.wantedItem.id] }
  }

  // MARK: - 7. Moves and deletes

  @Test(
    """
    An item moved between two lists keeps its ID, and shows on the new list. A list deleted elsewhere goes, with \
    its items, its recipient rows and its invitations
    """
  )
  func movedAndDeleted() async throws {
    let family = try await builder.standardFamily()
    let parentsList = try await builder.primaryList(of: family.parent)
    let scarf = try await builder.item("Scarf", on: parentsList, as: family.parent)
    let chair = try await builder.item("Chair", on: family.parentList, as: family.parent)
    let parent = try await signedIn(as: family.parent)
    try await inStep(parent)
    let session = parent.session
    #expect(session.invitations.map(\.id) == [family.pendingInvitation.id])
    #expect(session.recipients(ofList: family.parentList.id).map(\.userID) == [family.parent.id])
    let own = try family.parent.signedIn()

    // The scarf moves from the primary list to the extra one, as its last item.
    try await own.send("PATCH", "/items/\(scarf.id)", json: ["list_id": .string(family.parentList.id)]).expecting(200)
    await session.syncNow()
    try await inStep(parent)
    #expect(session.items(onList: parentsList.id).isEmpty)
    #expect(Set(session.items(onList: family.parentList.id).map(\.id)) == [chair.id, scarf.id])
    #expect(session.item(id: scarf.id)?.listID == family.parentList.id)

    // The extra list goes, with both items, its recipient row and the invitation to it.
    try await own.send("DELETE", "/lists/\(family.parentList.id)").expecting(204)
    let mark = parent.mark
    await session.syncNow()
    try await inStep(parent)
    #expect(parent.asked(since: mark) == ["GET /versions"])
    #expect(session.list(id: family.parentList.id) == nil)
    #expect(session.items(onList: family.parentList.id).isEmpty)
    #expect(session.item(id: scarf.id) == nil)
    #expect(session.item(id: chair.id) == nil)
    #expect(session.recipients(ofList: family.parentList.id).isEmpty)
    #expect(session.invitations.isEmpty)
    #expect(session.yourLists.map(\.id) == [parentsList.id])
  }

  @Test(
    """
    A list that goes while its items are on their way is removed with its items, and the pull goes on to the \
    other lists
    """
  )
  func listGoesDuringThePull() async throws {
    let family = try await builder.standardFamily()
    let parentsList = try await builder.primaryList(of: family.parent)
    let parent = try await signedIn(as: family.parent)
    try await inStep(parent)
    let session = parent.session
    let own = try family.parent.signedIn()

    // Two items on the extra list, so the pull reads the list's items. One on the primary list, which comes first.
    _ = try await builder.item("Scarf", on: parentsList, as: family.parent)
    _ = try await builder.item("Chair", on: family.parentList, as: family.parent)
    _ = try await builder.item("Lamp", on: family.parentList, as: family.parent)
    let robinsList = try await builder.primaryList(of: family.child)
    _ = try await builder.item("Kite", on: robinsList, as: family.child)

    let hold = parent.instance.conditioner.hold(Route("GET", "/lists/{id}/items"), at: .request)
    async let syncing = session.syncNow()
    await hold.waitUntilHeld()
    #expect(parent.instance.conditioner.requests.last?.target.contains("/lists/\(family.parentList.id)/items") == true)
    try await own.send("DELETE", "/lists/\(family.parentList.id)").expecting(204)
    hold.release()
    _ = await syncing

    // The list's collection answered 404. The list went, and the pull went on to the child's list.
    await until { session.items(onList: robinsList.id).map(\.title) == ["Kite"] }
    #expect(!session.isInstanceUnreachable)
    #expect(session.list(id: family.parentList.id) == nil)
    #expect(session.items(onList: parentsList.id).map(\.title) == ["Scarf"])

    // The pull didn't agree with its answer, so it kept no ETag. The next one compares, fetches nothing, and
    // removes the invitation to the list, which the answer before it still named.
    #expect(session.invitations.map(\.id) == [family.pendingInvitation.id])
    let mark = parent.mark
    await session.syncNow()
    #expect(parent.asked(since: mark) == ["GET /versions"])
    #expect(parent.instance.conditioner.requests.last?.headers["if-none-match"] == nil)
    try await inStep(parent)
    #expect(session.invitations.isEmpty)
  }

  @Test(
    """
    A list that goes while its recipient rows are on their way is removed with its items, and the pull goes on to \
    the other lists
    """
  )
  func listGoesWhileItsRecipientsAreOnTheirWay() async throws {
    let family = try await builder.standardFamily()
    // The child shares the parent's extra list, which has an item.
    try await builder.accept(try await builder.invite(family.child, to: family.parentList, as: family.parent))
    let chair = try await builder.item("Chair", on: family.parentList, as: family.parent)
    let parent = try await signedIn(as: family.parent)
    try await inStep(parent)
    let session = parent.session
    #expect(session.item(id: chair.id) != nil)

    // The child leaves, so the list's recipient rows change, and the pull reads them. Everyone else's lists come
    // after the parent's own: the child's list gains an item.
    try await family.child.signedIn().send(
      "DELETE", "/lists/\(family.parentList.id)/recipients/\(family.child.id)"
    ).expecting(204)
    let robinsList = try await builder.primaryList(of: family.child)
    _ = try await builder.item("Kite", on: robinsList, as: family.child)

    let hold = parent.instance.conditioner.hold(Route("GET", "/lists/{id}/recipients"), at: .request)
    async let syncing = session.syncNow()
    await hold.waitUntilHeld()
    #expect(
      parent.instance.conditioner.requests.last?.target.contains("/lists/\(family.parentList.id)/recipients") == true)
    try await family.parent.signedIn().send("DELETE", "/lists/\(family.parentList.id)").expecting(204)
    hold.release()
    _ = await syncing

    // The list's recipients answered 404. The list went with its item, and the pull went on to the child's list.
    await until { session.items(onList: robinsList.id).map(\.title) == ["Kite"] }
    #expect(!session.isInstanceUnreachable)
    #expect(session.list(id: family.parentList.id) == nil)
    #expect(session.item(id: chair.id) == nil)
    #expect(session.recipients(ofList: family.parentList.id).isEmpty)

    // The pull didn't agree with its answer, so it kept no ETag. The next one compares, and the copy is in step.
    let mark = parent.mark
    await session.syncNow()
    #expect(parent.instance.conditioner.requests.dropFirst(mark).first?.headers["if-none-match"] == nil)
    try await inStep(parent)
  }

  // MARK: - 8. Invitations

  @Test("An invitation accepted elsewhere goes, and the user is among the list's recipients, and in your lists")
  func acceptedElsewhere() async throws {
    let family = try await builder.standardFamily()
    let invitation = try await builder.invite(family.child, to: family.parentList, as: family.parent)
    let child = try await signedIn(as: family.child)
    try await inStep(child)
    let session = child.session
    let held = try #require(session.invitations.first { $0.id == invitation.id })
    #expect(held.listID == family.parentList.id)
    #expect(held.listName == family.parentList.name)
    #expect(held.userID == family.child.id)
    #expect(held.invitedByID == family.parent.id)
    #expect(held.canAccept)
    #expect(!session.yourLists.contains { $0.id == family.parentList.id })

    try await builder.accept(invitation)
    await session.syncNow()
    try await inStep(child)
    #expect(!session.invitations.contains { $0.id == invitation.id })
    #expect(session.list(id: family.parentList.id)?.recipientIDs == [family.parent.id, family.child.id])
    #expect(
      session.recipients(ofList: family.parentList.id).map(\.userID) == [family.parent.id, family.child.id])
    #expect(session.yourLists.contains { $0.id == family.parentList.id })
  }

  // MARK: - 9. A recipient seen only as a summary

  @Test("A recipient whom the user sees only as a summary is held as a summary, with no page")
  func recipientAsASummary() async throws {
    let family = try await builder.standardFamily()
    // The relative sees the child, and so the list that the child shares with the deactivated child. With the
    // parent out of the relative's groups, no user that the relative sees names the deactivated child.
    try await family.admin.signedIn().send(
      "DELETE", "/groups/\(family.household.id)/users/\(family.parent.id)"
    ).expecting(204)
    #expect(try await family.relative.signedIn().status(of: "/users/\(family.deactivatedChild.id)") == 404)

    let relative = try await signedIn(as: family.relative)
    try await inStep(relative)
    let session = relative.session
    let sam = try #require(session.user(id: family.deactivatedChild.id))
    #expect(sam.isSummary)
    #expect(sam.record == nil)
    #expect(sam.name == family.deactivatedChild.name)
    #expect(session.list(id: family.sharedList.id)?.recipientIDs == [family.deactivatedChild.id, family.child.id])
    #expect(session.recipients(ofList: family.sharedList.id).contains { $0.userID == family.deactivatedChild.id })
    // The deactivated child's own lists are not visible to the relative.
    #expect(session.list(id: family.primaryList.id) == nil)
    #expect(!relative.asked().contains("GET /users/\(family.deactivatedChild.id)"))

    // The copy agrees with the answer, so the next sync is one request, answered 304.
    let mark = relative.mark
    await session.syncNow()
    #expect(relative.asked(since: mark) == ["GET /versions"])
    #expect(relative.instance.conditioner.requests.last?.headers["if-none-match"] != nil)
  }

  @Test(
    """
    A summary that is left with another version, and that no body of the copy holds, goes from the copy: nothing \
    would bring its new name
    """
  )
  func summaryThatNoBodyHolds() async throws {
    let family = try await builder.standardFamily()
    try await family.admin.signedIn().send(
      "DELETE", "/groups/\(family.household.id)/users/\(family.parent.id)"
    ).expecting(204)
    let relative = try await signedIn(as: family.relative)
    try await inStep(relative)
    let session = relative.session
    #expect(session.user(id: family.deactivatedChild.id)?.isSummary == true)

    // The instance's own answer, with the shared list and the gift to the deactivated child gone, and another
    // version for the deactivated child's summary: no body of the copy holds the summary now.
    let shared = family.sharedList.id
    var answer = try #require(try await family.relative.signedIn().get("/versions")["data"].array)
    let itemsOfShared = Set(
      answer.filter { $0["kind"] == "item" && $0["list_id"].string == shared }.compactMap { $0["id"].string })
    answer.removeAll {
      $0["id"].string == shared || $0["list_id"].string == shared
        || $0["item_id"].string.map(itemsOfShared.contains) == true
        || ($0["kind"] == "gift" && $0["id"].string == family.givenGift.id)
    }
    answer = answer.map { entry in
      guard entry["kind"] == "user_summary", entry["id"].string == family.deactivatedChild.id else { return entry }
      return ["kind": "user_summary", "id": entry["id"], "version": "\"renamed\"", "list_id": nil, "item_id": nil]
    }
    relative.instance.conditioner.answer(
      Route("GET", "/versions"),
      with: .init(
        status: 200, headers: ["Content-Type": "application/json", "ETag": "\"canned\""],
        body: try JSON.object(["data": .array(answer)]).data))

    // The copy ends with what the answer names, but for the summary. The pull removes the list in one change, and
    // the summary in a later one, and the session publishes each change. So the wait is for the whole copy, never
    // for the list alone. The wait runs during the sync, so that it sees the change between the two.
    let renamed = "user_summary \(family.deactivatedChild.id) \"renamed\""
    let named = entries(in: answer)
    #expect(named.contains(renamed))
    let mark = relative.mark
    let sync = Task { await session.syncNow() }
    await until { entries(of: session) == named.subtracting([renamed]) }
    #expect(entries(of: session) == named.subtracting([renamed]))
    #expect(session.list(id: shared) == nil)
    #expect(session.user(id: family.deactivatedChild.id) == nil)
    #expect(await sync.value == .succeeded)
    #expect(relative.asked(since: mark) == ["GET /versions"])
    #expect(!session.isInstanceUnreachable)
  }

  // MARK: - 10. With no network

  @Test(
    "After a relaunch with the network dropped, the lists, items, store links, recipients and invitations still read")
  func relaunchOffline() async throws {
    let family = try await builder.standardFamily()
    let parentsList = try await builder.primaryList(of: family.parent)
    _ = try await builder.item(
      "Scarf", on: parentsList, as: family.parent, storeLinks: [("https://shop.example/scarf", 2500)])
    let folder = try ScratchDirectory("device")
    let saved: (lists: [ListRow], items: [ItemRow], entries: Set<String>, invitations: [InvitationRow])
    let instance: Instance
    do {
      // The device goes at the end of this scope, as the app does when it ends.
      let signed = try await signedIn(as: family.parent, storage: .folder(folder.url))
      try await inStep(signed)
      let session = signed.session
      saved = (session.lists, items(of: session), entries(of: session), session.invitations)
      instance = signed.instance
    }
    #expect(
      Set(saved.entries.compactMap { $0.split(separator: " ").first.map(String.init) }).isSuperset(of: Self.kinds))

    instance.conditioner.dropEverything()
    let relaunched = instance.device(storage: .folder(folder.url), timeZone: .fixed(Self.zone))

    // What is saved shows at once, before anything is asked of the instance.
    let session = try #require(relaunched.session)
    #expect(session.lists == saved.lists)
    #expect(items(of: session) == saved.items)
    #expect(entries(of: session) == saved.entries)
    #expect(session.invitations == saved.invitations)
    #expect(session.yourLists.map(\.id) == [parentsList.id, family.parentList.id])

    await session.syncNow()
    #expect(session.isInstanceUnreachable)
    #expect(entries(of: session) == saved.entries)
  }
}
