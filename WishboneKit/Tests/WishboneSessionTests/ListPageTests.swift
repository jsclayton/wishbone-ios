import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// A list's page, from the copy: its recipients for the "For {names}" line, the items with their claim state as the
/// server sends it, the line that says why items can be missing, the "For" line's links, the empty state, and the
/// sort. See `docs/screens/list.md`.
@Suite("A list's page", .timeLimit(.minutes(1)))
@MainActor
struct ListPageTests {
  /// An item as a test names it: its title, and its claim state.
  struct Row: Equatable, CustomStringConvertible {
    let title: String
    let claim: UserPage.Claim?

    var description: String {
      guard let claim else { return "\(title): no claim state" }
      return
        "\(title): \(claim.stillWanted.map(String.init) ?? "always") of \(claim.quantity), mine \(claim.youClaimed)"
    }
  }

  /// A new device, signed in as the person. Its first sync has ended, and the session publishes all that it
  /// wrote.
  private func signedIn(as person: Fixture.Person, on instance: Instance) async throws -> SessionModel {
    let instance = try await Instance(server: instance.server)
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    try await untilInStep(session, as: person)
    return session
  }

  private func rows(_ items: [UserPage.Item]) -> [Row] {
    items.map { Row(title: $0.row.title, claim: $0.claim) }
  }

  /// The standard family, with an extra list of the active child's holding three items: two of a scarf, one of
  /// which the relative claimed; a book that another giver claimed in full; and socks that are always wanted.
  private func childsListWithItems(on instance: Instance) async throws -> (StandardFamily, Fixture.List) {
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.list("Birthday", of: family.child)
    let scarf = try await builder.item("Scarf", on: list, as: family.child, quantity: 2)
    let book = try await builder.item("Book", on: list, as: family.child)
    _ = try await builder.item("Socks", on: list, as: family.child, isUnlimited: true)
    let aunt = try await builder.person("Avery")
    _ = try await builder.group("Aunts", users: [aunt, family.child])
    _ = try await builder.claim(scarf, as: family.relative, for: family.groupOccasion)
    _ = try await builder.claim(book, as: aunt)
    return (family, list)
  }

  @Test("A giver gets the rows with their claim state, and the recipients' names")
  func giver() async throws {
    let instance = try await Instance()
    let (family, list) = try await childsListWithItems(on: instance)
    let session = try await signedIn(as: family.relative, on: instance)

    let page = try #require(session.listPage(id: list.id))
    #expect(page.list.name == list.name)
    #expect(page.recipients.map(\.user.id) == [family.child.id])
    #expect(page.recipients.map(\.user.name) == [family.child.name])
    #expect(page.recipients.allSatisfy { $0.isLinked && !$0.isDeactivated })
    #expect(!page.isRecipient)
    #expect(!page.seesWhyItemsAreMissing)
    #expect(page.noItems == nil)
    #expect(
      rows(page.items) == [
        Row(title: "Scarf", claim: UserPage.Claim(stillWanted: 1, quantity: 2, youClaimed: 1)),
        Row(title: "Socks", claim: UserPage.Claim(stillWanted: nil, quantity: 1, youClaimed: 0)),
      ])
  }

  @Test("A recipient gets every item, and none of the claim state")
  func recipient() async throws {
    let instance = try await Instance()
    let (family, list) = try await childsListWithItems(on: instance)
    let session = try await signedIn(as: family.child, on: instance)

    let page = try #require(session.listPage(id: list.id))
    #expect(page.isRecipient)
    #expect(!page.seesWhyItemsAreMissing)
    #expect(
      rows(page.items) == [
        Row(title: "Scarf", claim: nil), Row(title: "Book", claim: nil), Row(title: "Socks", claim: nil),
      ])
    #expect(page.items.allSatisfy { $0.row.stillWanted.isHidden && $0.row.myClaimedQuantity.isHidden })
  }

  @Test("A parent who is not a recipient gets the claim state, the edit controls, and the line that says why")
  func parentWhoIsNotARecipient() async throws {
    let instance = try await Instance()
    let (family, list) = try await childsListWithItems(on: instance)
    let session = try await signedIn(as: family.parent, on: instance)

    let page = try #require(session.listPage(id: list.id))
    #expect(!page.isRecipient)
    #expect(page.list.canEdit)
    #expect(page.seesWhyItemsAreMissing)
    #expect(
      rows(page.items) == [
        Row(title: "Scarf", claim: UserPage.Claim(stillWanted: 1, quantity: 2, youClaimed: 0)),
        Row(title: "Socks", claim: UserPage.Claim(stillWanted: nil, quantity: 1, youClaimed: 0)),
      ])
  }

  @Test("A parent of a deactivated child, who can't edit the child's list, gets the line that says why")
  func parentOfADeactivatedChild() async throws {
    let instance = try await Instance()
    let family = try await instance.builder.standardFamily()
    let session = try await signedIn(as: family.parent, on: instance)

    let page = try #require(session.listPage(id: family.primaryList.id))
    #expect(!page.isRecipient)
    #expect(!page.list.canEdit)
    #expect(page.seesWhyItemsAreMissing)
  }

  @Test("Each name on the \"For\" line links its own name, never a match inside an earlier word or the \"and\"")
  func forLineLinks() throws {
    let deactivated = { (name: String) in "\(name) (Deactivated)" }
    func url(_ id: String) throws -> URL { try #require(URL(string: "test://user/\(id)")) }
    /// The line as text, with each linked span in brackets and its user ID after it: "[Grandpa](1) (Deactivated)".
    /// So a link on the wrong span, such as the "d" at the end of "Deactivated", gives other text.
    func marked(_ line: AttributedString) -> String {
      line.runs.map { run in
        let words = String(line[run.range].characters)
        return run.link.map { "[\(words)](\($0.lastPathComponent))" } ?? words
      }.joined()
    }

    // A short lowercase name after a deactivated one: "d" is in "(Deactivated)", and "an" is in "and".
    let line = ListPage.forLineNames(
      [
        ListPage.ForLineName(name: "Grandpa", isDeactivated: true, link: try url("1")),
        ListPage.ForLineName(name: "d", isDeactivated: false, link: try url("2")),
        ListPage.ForLineName(name: "an", isDeactivated: false, link: try url("3")),
      ],
      deactivated: deactivated)
    #expect(String(line.characters) == ["Grandpa (Deactivated)", "d", "an"].formatted(.list(type: .and)))
    #expect(marked(line) == ["[Grandpa](1) (Deactivated)", "[d](2)", "[an](3)"].formatted(.list(type: .and)))

    // A name with no link is only a name, and the names after it keep theirs.
    let unlinked = ListPage.forLineNames(
      [
        ListPage.ForLineName(name: "Sam", isDeactivated: false, link: nil),
        ListPage.ForLineName(name: "a", isDeactivated: false, link: try url("4")),
      ],
      deactivated: deactivated)
    #expect(String(unlinked.characters) == ["Sam", "a"].formatted(.list(type: .and)))
    #expect(marked(unlinked) == ["Sam", "[a](4)"].formatted(.list(type: .and)))
  }

  @Test("A recipient whom the viewer can't see is a name with no link, and \"Deactivated\" shows only to a parent")
  func recipientsTheViewerCantSee() async throws {
    let instance = try await Instance()
    let family = try await instance.builder.standardFamily()

    // The child shares the list with their deactivated sibling, whom they get only as a summary.
    let child = try await signedIn(as: family.child, on: instance)
    let shared = try #require(child.listPage(id: family.sharedList.id))
    let sibling = try #require(shared.recipients.first { $0.user.id == family.deactivatedChild.id })
    #expect(sibling.user.name == family.deactivatedChild.name)
    #expect(!sibling.isLinked)
    #expect(!sibling.isDeactivated)
    #expect(shared.recipients.first { $0.user.id == family.child.id }?.isLinked == true)

    // Their parent sees both in full, and the sibling as deactivated.
    let parent = try await signedIn(as: family.parent, on: instance)
    let asParent = try #require(parent.listPage(id: family.sharedList.id))
    #expect(asParent.recipients.allSatisfy { $0.isLinked })
    #expect(asParent.recipients.filter(\.isDeactivated).map(\.user.id) == [family.deactivatedChild.id])
  }

  @Test("List order, Price with the items that have no price last, and Newest")
  func sort() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.list("Wishes", of: family.child)
    func link(_ cents: Int?) -> [(url: String, priceMinor: Int?)] {
      cents.map { [(url: "https://example.com/\($0)", priceMinor: $0)] } ?? []
    }
    _ = try await builder.item("Lamp", on: list, as: family.child, storeLinks: link(2500))
    _ = try await builder.item("Mug", on: list, as: family.child)
    _ = try await builder.item("Pen", on: list, as: family.child, storeLinks: link(300))
    _ = try await builder.item("Rug", on: list, as: family.child, storeLinks: link(9900))
    _ = try await builder.item("Cup", on: list, as: family.child)
    let session = try await signedIn(as: family.relative, on: instance)

    let page = try #require(session.listPage(id: list.id))
    #expect(page.items(sortedBy: .listOrder).map(\.row.title) == ["Lamp", "Mug", "Pen", "Rug", "Cup"])
    #expect(page.items(sortedBy: .price).map(\.row.title) == ["Pen", "Lamp", "Rug", "Mug", "Cup"])
    #expect(page.items(sortedBy: .newest).map(\.row.title) == ["Cup", "Rug", "Pen", "Mug", "Lamp"])
  }

  @Test("With no items, a giver and someone who can edit get different words")
  func noItems() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.list("Empty", of: family.child)

    let giver = try await signedIn(as: family.relative, on: instance)
    let asGiver = try #require(giver.listPage(id: list.id))
    #expect(asGiver.items.isEmpty)
    #expect(asGiver.noItems == .forGiver)

    let recipient = try await signedIn(as: family.child, on: instance)
    #expect(try #require(recipient.listPage(id: list.id)).noItems == .forEditor)

    let parent = try await signedIn(as: family.parent, on: instance)
    #expect(try #require(parent.listPage(id: list.id)).noItems == .forEditor)
  }

  @Test("A list that is gone, or that the viewer can't see, gives the \"not found\" page")
  func notFound() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.list("Short-lived", of: family.child)
    // This test syncs again, so it keeps the device's instance, whose network the device goes through.
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: family.relative))
    let session = try #require(device.session)
    try await untilInStep(session, as: family.relative)
    #expect(session.listPage(id: list.id) != nil)

    _ = try await family.child.signedIn().send("DELETE", "/lists/\(list.id)").expecting(204)
    await session.syncNow()
    await until { session.listPage(id: list.id) == nil }
    #expect(session.listPage(id: family.parentList.id) != nil)

    let outsider = try await signedIn(as: family.outsider, on: instance)
    #expect(outsider.listPage(id: family.parentList.id) == nil)
    #expect(outsider.listPage(id: "0") == nil)
  }
}
