import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// The gifts and the blocked stores: after sign-in, the copy holds the gifts that the session's user gives, has
/// given and has received, and the gifts given to their children, and the admin's copy holds the blocked stores.
/// With the gifts, the copy holds every kind that `GET /versions` names. See "What the copy holds" in
/// `docs/spec.md`.
@Suite(
  "After sign-in, the gifts and the admin's blocked stores are in the copy, and the copy is whole",
  .timeLimit(.minutes(2)))
@MainActor
struct GiftsTests {
  typealias Route = NetworkConditioner.Route

  /// The time zone of every device of this suite, and of every user who signs in.
  static let zone = "Europe/Paris"

  /// Every kind that the server at the pinned version names in `GET /versions`. The copy holds each of them.
  static let kinds: Set<String> = [
    "user", "user_summary", "group", "occasion", "group_users", "users_in_group", "users_of_occasion",
    "group_groups", "occasion_groups", "list", "list_recipient", "item", "store_link", "invitation", "gift",
  ]

  /// The request for the blocked stores, as `asked(since:)` gives it.
  static let blockedStoresRequest = "GET /blocked-stores?limit=\(APIClient.pageSize)"

  /// Each test has a server of its own. So the versions that the instance names are the ones of this test's own
  /// family, and the admin's blocked stores are this family's only.
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

    /// What the device asked of the instance after the mark, oldest first, such as `GET /gifts/12`: the method,
    /// and the path under `/api/v2` with any query.
    func asked(since mark: Int = 0) -> [String] {
      instance.conditioner.requests.dropFirst(mark).map {
        "\($0.method) \($0.target.dropFirst(TestServer.apiPrefix.count))"
      }
    }

    /// Whether the first request after the mark, the one to `GET /versions`, carried the kept `ETag`.
    func sentKeptETag(since mark: Int) -> Bool {
      instance.conditioner.requests.dropFirst(mark).first?.headers["if-none-match"] != nil
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
  private func signedIn(as person: Fixture.Person, storage: SessionStorage = .memory) async throws -> Signed {
    try await setZone(of: person)
    let instance = try await Instance(server: server)
    let device = instance.device(storage: storage, timeZone: .fixed(Self.zone))
    await device.signIn(pasting: try await instance.loginLink(for: person))
    return Signed(person: person, instance: instance, device: device, session: try #require(device.session))
  }

  // MARK: - The copy, and the instance's own answers

  /// What the copy holds, as the entries of `GET /versions` are: `kind id version`. A recipient row is named by
  /// its list and its user, an item by its list too, and a store link by its item too.
  private func entries(of session: SessionModel) -> Set<String> {
    var entries: Set<String> = []
    for list in session.lists {
      entries.insert("list \(list.id) \(list.version)")
      for row in session.recipients(ofList: list.id) {
        entries.insert("list_recipient \(row.listID)/\(row.userID) \(row.version)")
      }
      for item in session.items(onList: list.id) {
        entries.insert("item \(item.listID)/\(item.id) \(item.version)")
        for link in session.storeLinks(ofItem: item.id) {
          entries.insert("store_link \(link.itemID)/\(link.id) \(link.version)")
        }
      }
    }
    for invitation in session.invitations {
      entries.insert("invitation \(invitation.id) \(invitation.version)")
    }
    for gift in session.gifts {
      entries.insert("gift \(gift.id) \(gift.version)")
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

  /// Every entry that the instance names for the person now, whatever its kind. The person's own session asks,
  /// not the device.
  private func entries(namedFor person: Fixture.Person) async throws -> Set<String> {
    let data = try await person.signedIn().get("/versions")["data"].array ?? []
    return Set(
      data.map { entry in
        let kind = entry["kind"].string ?? ""
        let id = entry["id"].string ?? ""
        let version = entry["version"].string ?? ""
        switch kind {
        case "list_recipient", "item": return "\(kind) \(entry["list_id"].string ?? "")/\(id) \(version)"
        case "store_link": return "\(kind) \(entry["item_id"].string ?? "")/\(id) \(version)"
        default: return "\(kind) \(id) \(version)"
        }
      })
  }

  /// Waits until the copy holds every entry that the instance names for the person, each with its version.
  private func inStep(_ signed: Signed, _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation)
    async throws
  {
    let named = try await entries(namedFor: signed.person)
    await until { entries(of: signed.session) == named }
    #expect(entries(of: signed.session) == named, comment, sourceLocation: sourceLocation)
  }

  /// The kinds of the copy's entries.
  private func kinds(of session: SessionModel) -> Set<String> {
    Set(entries(of: session).compactMap { $0.split(separator: " ").first.map(String.init) })
  }

  /// A member of an object, nil when the key is absent: the server hides the field.
  private func member(_ json: JSON, _ key: String) -> JSON? {
    if case .object(let members) = json { members[key] } else { nil }
  }

  /// A flag as the copy holds it, reduced to what a test compares: its code, and its fields with each user as an
  /// ID.
  private func reduced(_ flag: GiftRow.Flag) throws -> JSON {
    func ids(_ ids: [String]?) -> JSON {
      ids.map { .array($0.map(JSON.string)) } ?? .null
    }
    return switch flag {
    case .changed(let lines):
      ["code": "changed", "detail": .array(try lines.map { try JSON(parsing: JSONEncoder().encode($0)) })]
    case .removed: ["code": "removed", "detail": nil]
    case .moved(let list):
      ["code": "moved", "detail": list.map { ["id": .string($0.id), "name": .string($0.name)] } ?? .null]
    case .occasionMoved: ["code": "occasion_moved", "detail": nil]
    case .noLongerShared: ["code": "no_longer_shared", "detail": nil]
    case .restored(let id): ["code": "restored", "detail": id.map(JSON.string) ?? .null]
    case .recipientsChanged(let old, let new): ["code": "recipients_changed", "detail": [ids(old), ids(new)]]
    case .unknown(let code): ["code": .string(code), "detail": nil]
    }
  }

  /// A flag as the server sends it, reduced as `reduced(_:)` reduces the copy's.
  private func reduced(_ json: JSON) -> JSON {
    func ids(_ json: JSON) -> JSON {
      json.array.map { .array($0.compactMap { $0["id"].string.map(JSON.string) }) } ?? .null
    }
    let code = json["code"]
    return switch code.string {
    case "changed": ["code": code, "detail": .array(json["fields"].array ?? [])]
    case "moved":
      ["code": code, "detail": json["list"].isNull ? .null : ["id": json["list"]["id"], "name": json["list"]["name"]]]
    case "restored": ["code": code, "detail": json["by"]["id"]]
    case "recipients_changed": ["code": code, "detail": [ids(json["old_recipients"]), ids(json["new_recipients"])]]
    default: ["code": code, "detail": nil]
    }
  }

  /// Checks each gift of the copy against the instance's own answer, as the device's person reads it, and the
  /// blocked stores against the admin's collection.
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

    for gift in signed.session.gifts {
      let answer = try await own.send("GET", "/gifts/\(gift.id)").expecting(200)
      let json = try answer.json
      let what = "gift \(gift.id)"
      expect(gift.version == answer.headers["etag"], "\(what): version")
      expect(gift.state.rawValue == json["state"].string, "\(what): state")
      expect(number(gift.quantity) == json["quantity"].number, "\(what): quantity")
      expect(gift.itemID == json["item"]["id"].string, "\(what): item.id")
      expect(gift.itemTitle == json["item"]["title"].string, "\(what): item.title")
      expect(gift.itemPrimaryImage?.id == json["item"]["primary_image"]["id"].string, "\(what): item.primary_image")
      expect(gift.listID == json["list"]["id"].string, "\(what): list.id")
      expect(gift.listName == json["list"]["name"].string, "\(what): list.name")
      expect(gift.title == json["title"].string, "\(what): title")
      expect(gift.image?.id == json["image"]["id"].string, "\(what): image")
      expect(number(gift.priceMinor) == json["price_minor"].number, "\(what): price_minor")
      expect(number(gift.topPriceMinor) == json["top_price_minor"].number, "\(what): top_price_minor")
      expect(gift.currency == json["currency"].string, "\(what): currency")
      let recipients: Hideable<[String]> =
        member(json, "recipients").map { value in
          .shown(value.array?.compactMap { $0["id"].string })
        } ?? .hidden
      expect(gift.recipientIDs == recipients, "\(what): recipients")
      expect(gift.giverID == json["giver"]["id"].string, "\(what): giver")
      expect(gift.giverName == json["giver_name"].string, "\(what): giver_name")
      expect(gift.fromLabel == json["from_label"].string, "\(what): from_label")
      expect(gift.occasion?.id == json["occasion"]["id"].string, "\(what): occasion.id")
      expect(gift.occasion?.kind.rawValue == json["occasion"]["kind"].string, "\(what): occasion.kind")
      expect(gift.occasion?.name == json["occasion"]["name"].string, "\(what): occasion.name")
      expect(gift.occasionName == json["occasion_name"].string, "\(what): occasion_name")
      expect(gift.occasionDate == json["occasion_date"].string, "\(what): occasion_date")
      expect(text(gift.revealAt) == json["reveal_at"].string, "\(what): reveal_at")
      expect(text(gift.givenAt) == json["given_at"].string, "\(what): given_at")
      expect(gift.isBought == (member(json, "is_bought").map { .shown($0.bool) } ?? .hidden), "\(what): is_bought")
      expect(gift.note == (member(json, "note").map { .shown($0.string) } ?? .hidden), "\(what): note")
      expect(
        gift.needsAttention == (member(json, "needs_attention").map { .shown($0.bool) } ?? .hidden),
        "\(what): needs_attention")
      let createdAt: Hideable<String> = member(json, "created_at").map { .shown($0.string) } ?? .hidden
      expect(gift.createdAt.map { $0.formatted(.iso8601) } == createdAt, "\(what): created_at")
      switch (gift.flags, member(json, "flags")) {
      case (.hidden, nil): break
      case (.shown(let flags), let value?):
        let (held, sent) = (try (flags ?? []).map(reduced), (value.array ?? []).map(reduced))
        expect(held == sent, "\(what): flags, held \(held), sent \(sent)")
      default: expect(false, "\(what): flags are hidden in one and shown in the other")
      }
      expect(gift.canEdit == json["can_edit"].bool, "\(what): can_edit")
      expect(gift.canDelete == json["can_delete"].bool, "\(what): can_delete")
      expect(gift.canRaiseQuantity == json["can_raise_quantity"].bool, "\(what): can_raise_quantity")
      expect(gift.canAcknowledge == json["can_acknowledge"].bool, "\(what): can_acknowledge")
      expect(gift.canRestore == json["can_restore"].bool, "\(what): can_restore")
      expect(gift.canAddAgain == json["can_add_again"].bool, "\(what): can_add_again")
    }

    guard signed.session.user?.record?.isAdmin == true else {
      expect(signed.session.blockedStores.isEmpty, "blocked stores of someone who is not the admin")
      return
    }
    let stores = try await own.all("/blocked-stores")
    let held = signed.session.blockedStores
    expect(Set(held.map(\.id)) == Set(stores.compactMap { $0["id"].string }), "blocked stores")
    for json in stores {
      guard let store = held.first(where: { $0.id == json["id"].string }) else { continue }
      let what = "blocked store \(store.id)"
      expect(store.store == json["store"].string, "\(what): store")
      expect(text(store.createdAt) == json["created_at"].string, "\(what): created_at")
      expect(store.canDelete == json["can_delete"].bool, "\(what): can_delete")
      expect(store.version == json["version"].string, "\(what): version")
    }
  }

  // MARK: - 1. The copy is whole

  @Test(
    """
    For each person of the family, after the first sync, every entry that the instance names is in the copy with \
    its version, whatever its kind, and the next sync is a 304
    """
  )
  func everyPersonsCopyIsWhole() async throws {
    let family = try await builder.standardFamily()
    let childsList = try await builder.primaryList(of: family.child)
    let kite = try await builder.item("Kite", on: childsList, as: family.child)
    _ = try await builder.claim(kite, as: family.parent, for: family.groupOccasion, note: "Get string too")
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

      // The copy agrees with the answer, so the next sync asks for the versions with the kept ETag, and nothing
      // else that the answer covers.
      let mark = signed.mark
      await signed.session.sync()
      let isAdmin = person.id == family.admin.id
      #expect(signed.asked(since: mark) == ["GET /versions"] + (isAdmin ? [Self.blockedStoresRequest] : []), "\(role)")
      #expect(signed.sentKeptETag(since: mark), "\(role)")
    }

    // Every kind that the instance named is one that the copy holds. The parent gives a gift, and sees the gifts
    // given to both children. The relative gave one. The child has received nothing yet.
    let named = held.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    #expect(named.isSubset(of: Self.kinds))
    #expect(held["the parent"]?.contains("gift") == true)
    #expect(held["the relative"]?.contains("gift") == true)
    #expect(held["the child"]?.contains("gift") == false)
  }

  @Test("On the first sync, the gifts are asked for with Home's data, before any list")
  func giftsAreHomesData() async throws {
    let family = try await builder.standardFamily()
    let childsList = try await builder.primaryList(of: family.child)
    let kite = try await builder.item("Kite", on: childsList, as: family.child)
    _ = try await builder.claim(kite, as: family.parent, for: family.groupOccasion)

    let parent = try await signedIn(as: family.parent)
    try await inStep(parent)
    let asked = parent.asked()
    let gifts = try #require(asked.firstIndex { $0.hasPrefix("GET /gifts") })
    let lastOfHome = try #require(
      asked.lastIndex { $0.hasPrefix("GET /users") || $0.hasPrefix("GET /groups") || $0.hasPrefix("GET /occasions") })
    let firstOfLists = try #require(
      asked.firstIndex { $0.hasPrefix("GET /lists") || $0.hasPrefix("GET /items") || $0.hasPrefix("GET /invitations") })
    #expect(gifts < firstOfLists)
    #expect(lastOfHome < firstOfLists)
  }

  // MARK: - 2. The fields by role

  @Test(
    """
    A giver's open gift has is_bought, note, flags and needs_attention, and a recipient's given gift has none of \
    them. A parent holds the gifts given to a child, and nobody holds an open gift that is for them
    """
  )
  func fieldsByRole() async throws {
    let family = try await builder.standardFamily()
    let childsList = try await builder.primaryList(of: family.child)
    let kite = try await builder.item("Kite", on: childsList, as: family.child)
    let gift = try await builder.claim(kite, as: family.relative, for: family.groupOccasion, note: "Wrap it")
    let parentsList = try await builder.primaryList(of: family.parent)
    let scarf = try await builder.item("Scarf", on: parentsList, as: family.parent)
    let forParent = try await builder.claim(scarf, as: family.relative, for: family.groupOccasion)

    let relative = try await signedIn(as: family.relative)
    try await inStep(relative)
    let open = try #require(relative.session.gift(id: gift.id))
    #expect(open.state == .open)
    #expect(open.isBought == .shown(false))
    #expect(open.note == .shown("Wrap it"))
    #expect(open.flags == .shown([]))
    #expect(!open.needsAttention.isHidden)
    #expect(!open.createdAt.isHidden)
    #expect(open.recipientIDs == .shown([family.child.id]))
    #expect(open.canEdit)
    try await expectEveryField(of: relative)

    // The recipient and their parent don't hold the open gift. The parent doesn't hold the one for them.
    let child = try await signedIn(as: family.child)
    try await inStep(child)
    #expect(child.session.gift(id: gift.id) == nil)
    let parent = try await signedIn(as: family.parent)
    try await inStep(parent)
    #expect(parent.session.gift(id: gift.id) == nil)
    #expect(parent.session.gift(id: forParent.id) == nil)
    // The parent holds the gift given to the deactivated child.
    #expect(parent.session.received(by: family.deactivatedChild.id).map(\.id) == [family.givenGift.id])

    // At reveal, the gift is given. The child and their parent hold it, with none of the giver's own fields.
    try await builder.reveal(giftsFor: family.child)
    for signed in [child, parent] {
      await signed.session.sync()
      try await inStep(signed)
      let given = try #require(signed.session.gift(id: gift.id))
      #expect(given.state == .given)
      #expect(given.isBought == .hidden)
      #expect(given.note == .hidden)
      #expect(given.flags == .hidden)
      #expect(given.needsAttention == .hidden)
      #expect(given.createdAt == .hidden)
      #expect(given.giverID == family.relative.id)
      #expect(given.canRestore)
      try await expectEveryField(of: signed)
    }
    #expect(parent.session.received(by: family.child.id).map(\.id) == [gift.id])

    // Nobody holds an open gift that someone else gives.
    for signed in [relative, child, parent] {
      await signed.session.sync()
      #expect(signed.session.gifts.filter { $0.state == .open }.allSatisfy { $0.giverID == signed.person.id })
    }
  }

  // MARK: - 3. Giving, Given, Received, and a child's Received

  @Test(
    """
    Giving, Given, Received and a child's Received, taken from the copy, equal the server's filtered collections, \
    and the count of gifts that need attention equals the server's
    """
  )
  func theFourViews() async throws {
    let family = try await builder.standardFamily()
    let childsList = try await builder.primaryList(of: family.child)
    let parentsList = try await builder.primaryList(of: family.parent)

    // The parent gave the child a book, and gives them a kite that the child then changed.
    let book = try await builder.item("Book", on: childsList, as: family.child)
    _ = try await builder.claim(book, as: family.parent, for: family.groupOccasion)
    try await builder.reveal(giftsFor: family.child)
    let kite = try await builder.item("Kite", on: childsList, as: family.child)
    _ = try await builder.claim(kite, as: family.parent, for: family.groupOccasion)
    try await family.child.signedIn().send("PATCH", "/items/\(kite.id)", json: ["title": "Red kite"]).expecting(200)
    // The relative gave the parent a scarf.
    let scarf = try await builder.item("Scarf", on: parentsList, as: family.parent)
    _ = try await builder.claim(scarf, as: family.relative, for: family.groupOccasion)
    try await builder.reveal(giftsFor: family.parent)

    let parent = try await signedIn(as: family.parent)
    try await inStep(parent)
    let session = parent.session
    let own = try family.parent.signedIn()
    func ids(_ path: String) async throws -> Set<String> {
      Set(try await own.all(path).compactMap { $0["id"].string })
    }

    let views: [(String, [GiftRow], String)] = [
      ("Giving", session.giving, "/gifts?giver_id=me&state=open"),
      ("Given", session.given, "/gifts?giver_id=me&state=given&sort=-given_at"),
      ("Received", session.received, "/gifts?recipient_id=me&sort=-given_at"),
      ("the child's Received", session.received(by: family.child.id), "/gifts?recipient_id=\(family.child.id)"),
      (
        "the deactivated child's Received", session.received(by: family.deactivatedChild.id),
        "/gifts?recipient_id=\(family.deactivatedChild.id)"
      ),
    ]
    for (name, gifts, path) in views {
      #expect(!gifts.isEmpty, "\(name)")
      #expect(Set(gifts.map(\.id)) == (try await ids(path)), "\(name)")
    }
    // Given and Received are the newest first.
    for gifts in [session.given, session.received, session.received(by: family.child.id)] {
      let dates = gifts.compactMap(\.givenAt)
      #expect(dates == dates.sorted(by: >))
    }
    #expect(session.giving.map(\.revealAt) == session.giving.map(\.revealAt).sorted())

    // The changed kite needs attention.
    let needing = try await ids("/gifts?needs_attention=true")
    #expect(!needing.isEmpty)
    #expect(session.giftsNeedingAttention == needing.count)
  }

  // MARK: - 4. Flags

  @Test("Each flag decodes with its fields, and a code that the app doesn't know is kept as unknown")
  func flags() async throws {
    let family = try await builder.standardFamily()
    let childsList = try await builder.primaryList(of: family.child)
    let toys = try await builder.list("Toys", of: family.child)
    let kite = try await builder.item("Kite", on: childsList, as: family.child)
    let gift = try await builder.claim(kite, as: family.relative, for: family.groupOccasion)

    // The child changes the title, prices the kite for the first time, changes the price, and moves the kite.
    let own = try family.child.signedIn()
    try await own.send(
      "PATCH", "/items/\(kite.id)", json: ["title": "Red kite", "price_minor": 1000, "currency": "USD"]
    ).expecting(200)
    try await own.send("PATCH", "/items/\(kite.id)", json: ["price_minor": 1500]).expecting(200)
    try await own.send("PATCH", "/items/\(kite.id)", json: ["list_id": .string(toys.id)]).expecting(200)

    let relative = try await signedIn(as: family.relative)
    try await inStep(relative)
    try await expectEveryField(of: relative)
    let flags = try #require(relative.session.gift(id: gift.id)?.flags.value)
    let price = { (minor: Int) in GiftChange.Value.price(.init(priceMinor: minor, currency: "USD")) }
    #expect(
      flags.first
        == .changed([
          GiftChange(field: .title, old: .shown(.text("Kite")), new: .shown(.text("Red kite"))),
          GiftChange(field: .price, old: .shown(price(1000)), new: .shown(price(1500))),
        ]))
    guard case .moved(let list) = flags.last else {
      Issue.record("The last flag is not moved: \(flags)")
      return
    }
    #expect(list?.id == toys.id)
    #expect(list?.name == toys.name)

    // The instance's own answer, with every code and one that the app doesn't know, and every kind of line.
    let answer = try await family.relative.signedIn().get("/gifts/\(gift.id)")
    guard case .object(var body) = answer else {
      Issue.record("The gift is not an object: \(answer)")
      return
    }
    let robin: JSON = ["id": .string(family.child.id), "name": .string(family.child.name), "avatar": nil]
    let sam: JSON = [
      "id": .string(family.deactivatedChild.id), "name": .string(family.deactivatedChild.name), "avatar": nil,
    ]
    let lines: [JSON] = [
      ["field": "notes", "old": nil, "new": "Blue"],
      ["field": "quantity", "old": 1, "new": 2],
      ["field": "is_unlimited", "old": false, "new": true],
      ["field": "primary_image"],
      [
        "field": "store_link_price", "url": "https://shop.example/kite",
        "old": ["price_minor": 900, "top_price_minor": nil, "currency": "USD"], "new": nil,
      ],
      ["field": "store_link_removed", "url": "https://gone.example/kite"],
      ["field": "colour", "old": ["red", "blue"], "new": "green"],
    ]
    body["flags"] = [
      ["code": "changed", "fields": .array(lines)],
      ["code": "removed"],
      ["code": "moved", "list": nil],
      ["code": "occasion_moved"],
      ["code": "no_longer_shared"],
      ["code": "restored", "by": robin],
      ["code": "recipients_changed", "old_recipients": [robin, sam], "new_recipients": nil],
      ["code": "gift_wrapped", "paper": "gold"],
    ]
    var entries = try #require(try await family.relative.signedIn().get("/versions")["data"].array)
    entries = entries.map { entry in
      guard entry["kind"] == "gift", entry["id"].string == gift.id else { return entry }
      return ["kind": "gift", "id": entry["id"], "version": "\"canned-gift\"", "list_id": nil, "item_id": nil]
    }
    let conditioner = relative.instance.conditioner
    conditioner.answer(
      Route("GET", "/versions"),
      with: .init(
        status: 200, headers: ["Content-Type": "application/json", "ETag": "\"canned\""],
        body: try JSON.object(["data": .array(entries)]).data))
    conditioner.answer(
      Route("GET", "/gifts/{id}"),
      with: .init(
        status: 200, headers: ["Content-Type": "application/json", "ETag": "\"canned-gift\""],
        body: try JSON.object(body).data))

    let mark = relative.mark
    await relative.session.sync()
    await until { relative.session.gift(id: gift.id)?.version == "\"canned-gift\"" }
    #expect(relative.asked(since: mark) == ["GET /versions", "GET /gifts/\(gift.id)"])
    let held = try #require(relative.session.gift(id: gift.id)?.flags.value)
    #expect(
      held == [
        .changed([
          GiftChange(field: .notes, old: .shown(nil), new: .shown(.text("Blue"))),
          GiftChange(field: .quantity, old: .shown(.number(1)), new: .shown(.number(2))),
          GiftChange(field: .isUnlimited, old: .shown(.boolean(false)), new: .shown(.boolean(true))),
          GiftChange(field: .primaryImage),
          GiftChange(
            field: .storeLinkPrice, url: "https://shop.example/kite", old: .shown(price(900)), new: .shown(nil)),
          GiftChange(field: .storeLinkRemoved, url: "https://gone.example/kite"),
          GiftChange(field: .unknown("colour"), old: .shown(.unknown), new: .shown(.text("green"))),
        ]),
        .removed,
        .moved(to: nil),
        .occasionMoved,
        .noLongerShared,
        .restored(byUserID: family.child.id),
        .recipientsChanged(oldUserIDs: [family.child.id, family.deactivatedChild.id], newUserIDs: nil),
        .unknown("gift_wrapped"),
      ])
    #expect(!relative.session.isInstanceUnreachable)
  }

  // MARK: - 5. A user only in a flag

  @Test("A user who is only in a flag of the user's gift is held as a summary")
  func userOnlyInAFlag() async throws {
    let family = try await builder.standardFamily()
    // Alex is in a club with the child, so the child can invite them. The relative is not in the club, and sees
    // Alex only on the list.
    let alex = try await builder.person("Alex")
    _ = try await builder.group("Club", users: [family.child, alex])
    let toys = try await builder.list("Toys", of: family.child)
    try await builder.accept(try await builder.invite(alex, to: toys, as: family.child))
    let blocks = try await builder.item("Blocks", on: toys, as: family.child)
    let gift = try await builder.claim(blocks, as: family.relative, for: family.groupOccasion)

    // Alex leaves. The relative's gift is flagged with the recipients that the relative last saw, Alex among them.
    try await alex.signedIn().send("DELETE", "/lists/\(toys.id)/recipients/\(alex.id)").expecting(204)
    #expect(try await family.relative.signedIn().status(of: "/users/\(alex.id)") == 404)

    let relative = try await signedIn(as: family.relative)
    try await inStep(relative)
    let session = relative.session
    let held = try #require(session.user(id: alex.id))
    #expect(held.isSummary)
    #expect(held.name == alex.name)
    let flags = try #require(session.gift(id: gift.id)?.flags.value)
    #expect(
      flags.contains { flag in
        guard case .recipientsChanged(let old, _) = flag else { return false }
        return old?.contains(alex.id) == true
      })
    // No other body of the copy names Alex.
    #expect(session.list(id: toys.id)?.recipientIDs == [family.child.id])
    #expect(session.gift(id: gift.id)?.recipientIDs == .shown([family.child.id]))
    #expect(!relative.asked().contains("GET /users/\(alex.id)"))

    let mark = relative.mark
    await session.sync()
    #expect(relative.asked(since: mark) == ["GET /versions"])
    #expect(relative.sentKeptETag(since: mark))
  }

  // MARK: - 6 and 7. Reveal and unclaim

  @Test("A gift that the server reveals is given at the next sync, and its recipient's copy gains it")
  func revealed() async throws {
    let family = try await builder.standardFamily()
    let childsList = try await builder.primaryList(of: family.child)
    let kite = try await builder.item("Kite", on: childsList, as: family.child)
    let gift = try await builder.claim(kite, as: family.relative, for: family.groupOccasion, fromLabel: "The cousins")

    let relative = try await signedIn(as: family.relative)
    try await inStep(relative)
    #expect(relative.session.gift(id: gift.id)?.state == .open)
    #expect(relative.session.gift(id: gift.id)?.givenAt == nil)
    let child = try await signedIn(as: family.child)
    try await inStep(child)
    #expect(child.session.gift(id: gift.id) == nil)
    #expect(child.session.received.isEmpty)

    try await builder.reveal(giftsFor: family.child)
    await relative.session.sync()
    try await inStep(relative)
    let given = try #require(relative.session.gift(id: gift.id))
    #expect(given.state == .given)
    #expect(given.givenAt != nil)
    #expect(given.flags == .hidden)
    #expect(given.needsAttention == .hidden)
    #expect(relative.session.giving.isEmpty)
    #expect(relative.session.given.map(\.id).contains(gift.id))

    await child.session.sync()
    try await inStep(child)
    #expect(child.session.received.map(\.id) == [gift.id])
    #expect(child.session.gift(id: gift.id)?.fromLabel == "The cousins")
    try await expectEveryField(of: child)
  }

  @Test("A gift that is unclaimed elsewhere leaves the copy")
  func unclaimedElsewhere() async throws {
    let family = try await builder.standardFamily()
    let childsList = try await builder.primaryList(of: family.child)
    let kite = try await builder.item("Kite", on: childsList, as: family.child)
    let gift = try await builder.claim(kite, as: family.relative, for: family.groupOccasion)

    let relative = try await signedIn(as: family.relative)
    try await inStep(relative)
    #expect(relative.session.giving.map(\.id) == [gift.id])

    try await family.relative.signedIn().send("DELETE", "/gifts/\(gift.id)").expecting(204)
    await relative.session.sync()
    try await inStep(relative)
    #expect(relative.session.gift(id: gift.id) == nil)
    #expect(relative.session.giving.isEmpty)
    #expect(!relative.asked().contains("GET /gifts/\(gift.id)"))
  }

  // MARK: - 8. Blocked stores

  @Test(
    """
    The admin holds the blocked stores. A store blocked elsewhere arrives at the next sync, though the versions \
    answered 304, and nobody else sends the request
    """
  )
  func blockedStores() async throws {
    let family = try await builder.standardFamily()
    let admin = try await signedIn(as: family.admin)
    try await inStep(admin)
    try await expectEveryField(of: admin)
    #expect(admin.session.blockedStores.map(\.id) == [family.blockedStore.id])
    #expect(admin.session.blockedStores.first?.store == family.blockedStore.store)
    #expect(admin.session.blockedStores.first?.canDelete == true)
    #expect(admin.asked().contains(Self.blockedStoresRequest))

    // Another store is blocked, and the first one is allowed again, elsewhere.
    let more = try await builder.blockedStore("more")
    try await family.admin.signedIn().send("DELETE", "/blocked-stores/\(family.blockedStore.id)").expecting(204)
    var mark = admin.mark
    await admin.session.sync()
    #expect(admin.asked(since: mark) == ["GET /versions", Self.blockedStoresRequest])
    #expect(admin.sentKeptETag(since: mark))
    #expect(admin.session.blockedStores.map(\.id) == [more.id])
    #expect(admin.session.blockedStores.map(\.store) == [more.store])

    // Saving them kept the ETag, so the next sync is a 304 again.
    mark = admin.mark
    await admin.session.sync()
    #expect(admin.asked(since: mark) == ["GET /versions", Self.blockedStoresRequest])
    #expect(admin.sentKeptETag(since: mark))

    // Nobody else asks for them, or holds any.
    for person in [family.parent, family.relative, family.outsider] {
      let signed = try await signedIn(as: person)
      await signed.session.sync()
      #expect(!signed.asked().contains { $0.contains("/blocked-stores") }, "\(person.name)")
      #expect(signed.session.blockedStores.isEmpty, "\(person.name)")
    }
  }

  // MARK: - 9. With no network

  @Test("After a relaunch with the network dropped, the gifts and the blocked stores still read")
  func relaunchOffline() async throws {
    let family = try await builder.standardFamily()
    let childsList = try await builder.primaryList(of: family.child)
    let kite = try await builder.item("Kite", on: childsList, as: family.child)
    _ = try await builder.claim(kite, as: family.parent, for: family.groupOccasion, note: "Get string too")

    for (person, held) in [(family.parent, "gifts"), (family.admin, "blocked stores")] {
      let folder = try ScratchDirectory("device")
      let saved: (gifts: [GiftRow], stores: [BlockedStoreRow], entries: Set<String>)
      let instance: Instance
      do {
        // The device goes at the end of this scope, as the app does when it ends.
        let signed = try await signedIn(as: person, storage: .folder(folder.url))
        try await inStep(signed)
        let session = signed.session
        saved = (session.gifts, session.blockedStores, entries(of: session))
        instance = signed.instance
      }
      #expect(!(held == "gifts" ? saved.gifts.isEmpty : saved.stores.isEmpty), "\(held)")

      instance.conditioner.dropEverything()
      let relaunched = instance.device(storage: .folder(folder.url), timeZone: .fixed(Self.zone))

      // What is saved shows at once, before anything is asked of the instance.
      let session = try #require(relaunched.session)
      #expect(session.gifts == saved.gifts, "\(held)")
      #expect(session.blockedStores == saved.stores, "\(held)")
      #expect(entries(of: session) == saved.entries, "\(held)")

      await session.sync()
      #expect(session.isInstanceUnreachable, "\(held)")
      #expect(session.gifts == saved.gifts, "\(held)")
      #expect(session.blockedStores == saved.stores, "\(held)")
    }
  }
}
