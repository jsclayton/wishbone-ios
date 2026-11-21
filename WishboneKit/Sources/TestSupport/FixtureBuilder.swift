import Foundation

/// What a fixture builder seeds, as typed handles. A handle holds what a test needs to find the thing again: its
/// ID, and its name.
public enum Fixture {
  /// A user of the instance.
  public struct Person: Sendable {
    public let id: String
    public let name: String

    /// The user's own bearer session. Nil for a user who can't sign in, such as a deactivated one.
    public let session: BearerSession?

    /// The user's session, or an error for a user who has none.
    public func signedIn() throws -> BearerSession {
      guard let session else { throw NotSignedIn(name: name) }
      return session
    }
  }

  public struct NotSignedIn: Error, CustomStringConvertible {
    public let name: String

    public var description: String {
      "\(name) has no session."
    }
  }

  public struct Group: Sendable {
    public let id: String
    public let name: String
  }

  public struct List: Sendable {
    public let id: String
    public let name: String
  }

  public struct Item: Sendable {
    public let id: String
    public let title: String
    public let list: List
  }

  public struct Occasion: Sendable {
    public let id: String
    public let name: String
  }

  public struct Invitation: Sendable {
    public let id: String
    public let list: List
    public let invited: Person
  }

  public struct Gift: Sendable {
    public let id: String
    public let item: Item
    public let giver: Person
  }

  public struct BlockedStore: Sendable {
    public let id: String
    public let store: String
  }
}

/// Seeds a test server through its API. It starts as the admin, and does the rest as each user, through that
/// user's own session. Nothing is written to the database or its folder.
///
/// Every test makes its own builder. A builder puts its own tag in each name, so the tests that share a server
/// can tell their users, groups, and stores apart. See "Fixtures" in `docs/development.md`.
public struct FixtureBuilder: Sendable {
  public let server: TestServer

  /// The instance's admin. The tests that share a server share the admin.
  public let admin: Fixture.Person

  /// What this builder adds to each name.
  public let tag: String

  private let adminSession: BearerSession

  public init(server: TestServer) async throws {
    self.server = server
    adminSession = try await server.admin()
    let me = try await adminSession.get("/users/me")
    admin = Fixture.Person(id: adminSession.userID, name: me["name"].string ?? "", session: adminSession)
    tag = String(UUID().uuidString.prefix(8).lowercased())
  }

  /// The name with this builder's tag: "Robin" as "Robin 1a2b3c4d".
  public func name(_ name: String) -> String {
    "\(name) \(tag)"
  }

  // MARK: - Users

  /// Makes a user, as the admin, and signs them in with a login link.
  public func person(
    _ name: String,
    birthday: (month: Int, day: Int) = (6, 15),
    parents: [Fixture.Person] = [],
    signedIn: Bool = true
  ) async throws -> Fixture.Person {
    let body: JSON = [
      "name": .string(self.name(name)),
      "birthday": ["month": .number(Double(birthday.month)), "day": .number(Double(birthday.day))],
      "parent_ids": .array(parents.map { .string($0.id) }),
    ]
    let user = try await adminSession.post("/users", body)
    let person = Fixture.Person(id: try id(of: user), name: self.name(name), session: nil)
    guard signedIn else { return person }
    return Fixture.Person(
      id: person.id, name: person.name, session: try await server.redeem(try await loginLink(for: person)))
  }

  /// A new login link for the user, made by the admin. It works once.
  public func loginLink(for person: Fixture.Person) async throws -> URL {
    let link = try await adminSession.post("/users/\(person.id)/login-links")
    guard let url = link["url"].string.flatMap(URL.init(string:)) else {
      throw Unreadable(what: "a login link", json: link)
    }
    return url
  }

  /// Deactivates the user, as the admin. The server revokes their sessions, so the handle that comes back has
  /// none.
  public func deactivate(_ person: Fixture.Person) async throws -> Fixture.Person {
    try await adminSession.post("/users/\(person.id)/deactivate")
    return Fixture.Person(id: person.id, name: person.name, session: nil)
  }

  // MARK: - Groups, shared occasions, and blocked stores

  /// Makes a group, as the admin, with the users directly in it and the groups nested in it.
  public func group(
    _ name: String,
    users: [Fixture.Person] = [],
    groups: [Fixture.Group] = []
  ) async throws -> Fixture.Group {
    let made = try await adminSession.post("/groups", ["name": .string(self.name(name))])
    let group = Fixture.Group(id: try id(of: made), name: self.name(name))
    for user in users {
      try await adminSession.post("/groups/\(group.id)/users", ["user_id": .string(user.id)])
    }
    for inner in groups {
      try await adminSession.post("/groups/\(group.id)/groups", ["group_id": .string(inner.id)])
    }
    return group
  }

  /// Makes a shared occasion on a fixed date of each year, as the admin. It is attached to the groups, or marked
  /// everyone.
  public func sharedOccasion(
    _ name: String,
    month: Int,
    day: Int,
    groups: [Fixture.Group] = [],
    isEveryone: Bool = false
  ) async throws -> Fixture.Occasion {
    let body: JSON = [
      "kind": "shared",
      "name": .string(self.name(name)),
      "rule": ["kind": "annual", "month": .number(Double(month)), "day": .number(Double(day))],
      "is_everyone": .bool(isEveryone),
    ]
    let made = try await adminSession.post("/occasions", body)
    let occasion = Fixture.Occasion(id: try id(of: made), name: self.name(name))
    for group in groups {
      try await adminSession.post("/occasions/\(occasion.id)/groups", ["group_id": .string(group.id)])
    }
    return occasion
  }

  /// Blocks a store, as the admin. The store's host name holds this builder's tag.
  public func blockedStore(_ name: String = "blocked") async throws -> Fixture.BlockedStore {
    let store = "\(name)-\(tag).example"
    let made = try await adminSession.post("/blocked-stores", ["store": .string(store)])
    return Fixture.BlockedStore(id: try id(of: made), store: made["store"].string ?? store)
  }

  // MARK: - Lists, items, and invitations

  /// The user's primary list, read as the user.
  public func primaryList(of person: Fixture.Person) async throws -> Fixture.List {
    let list = try await person.signedIn().get("/users/me")["primary_list"]
    return Fixture.List(id: try id(of: list), name: list["name"].string ?? "")
  }

  /// Makes an extra list, as the user who is its first recipient.
  public func list(_ name: String, of person: Fixture.Person) async throws -> Fixture.List {
    let made = try await person.signedIn().post("/lists", ["name": .string(self.name(name))])
    return Fixture.List(id: try id(of: made), name: self.name(name))
  }

  /// Adds an item to the list, as a user who can edit the list.
  public func item(_ title: String, on list: Fixture.List, as editor: Fixture.Person) async throws -> Fixture.Item {
    let made = try await editor.signedIn().post("/lists/\(list.id)/items", ["title": .string(title)])
    return Fixture.Item(id: try id(of: made), title: title, list: list)
  }

  /// Invites the user to the extra list, as one of its recipients. The invitation stays pending.
  public func invite(
    _ invited: Fixture.Person,
    to list: Fixture.List,
    as recipient: Fixture.Person
  ) async throws -> Fixture.Invitation {
    let made = try await recipient.signedIn().post("/lists/\(list.id)/invitations", ["user_id": .string(invited.id)])
    return Fixture.Invitation(id: try id(of: made), list: list, invited: invited)
  }

  /// Accepts the invitation, as the invited user, who becomes a recipient of the list.
  public func accept(_ invitation: Fixture.Invitation) async throws {
    try await invitation.invited.signedIn().post("/invitations/\(invitation.id)/accept")
  }

  // MARK: - Gifts

  /// Claims the item, as the giver. With no occasion, the server picks the soonest one that the giver may pick.
  /// That pick moves with the date, and on a shared server it can be an occasion for everyone that another test
  /// made. A test that reads the gift's occasion names one.
  public func claim(
    _ item: Fixture.Item,
    as giver: Fixture.Person,
    for occasion: Fixture.Occasion? = nil,
    fromLabel: String? = nil,
    note: String? = nil
  ) async throws -> Fixture.Gift {
    var body: [String: JSON] = [:]
    body["occasion_id"] = occasion.map { .string($0.id) }
    body["from_label"] = fromLabel.map { .string($0) }
    body["note"] = note.map { .string($0) }
    let made = try await giver.signedIn().post("/items/\(item.id)/gifts", .object(body))
    return Fixture.Gift(id: try id(of: made), item: item, giver: giver)
  }

  /// Gives the open gifts on the lists that the user is a recipient of, as their reveal does. It goes through the
  /// server's test hook, which gives the gifts whose reveal comes within `days` from now. It moves no clock.
  /// Returns how many gifts it gave.
  @discardableResult
  public func reveal(giftsFor recipient: Fixture.Person, within days: Int = 400) async throws -> Int {
    guard let recipientID = Double(recipient.id) else {
      throw Unreadable(what: "a user's ID", json: .string(recipient.id))
    }
    let body: JSON = ["recipient": .number(recipientID), "advance": .string("\(days * 24)h")]
    let hook = server.address.appending(path: "/api/e2e/reveal")
    let answer = try await TestHTTP.send("POST", hook, json: body).expecting(200).json
    return Int(answer["revealed"].number ?? 0)
  }

  // MARK: - Reading the server's answers

  public struct Unreadable: Error, CustomStringConvertible {
    public let what: String
    public let json: JSON

    public var description: String {
      "The server's answer is not \(what): \(json)"
    }
  }

  private func id(of json: JSON) throws -> String {
    guard let id = json["id"].string else { throw Unreadable(what: "a resource with an ID", json: json) }
    return id
  }
}
