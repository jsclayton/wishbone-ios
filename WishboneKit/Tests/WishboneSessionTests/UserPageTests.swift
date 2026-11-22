import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// A user's page, from the copy: the header, the line for a special case, the items of the primary list with their
/// claim state as the server sends it, and Other lists. See `docs/screens/user.md`.
@Suite("A user's page", .timeLimit(.minutes(1)))
@MainActor
struct UserPageTests {
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
  /// wrote. Each device has a keychain of its own, so a test can sign several people in on one server.
  private func signedIn(as person: Fixture.Person, on instance: Instance) async throws -> SessionModel {
    let instance = try await Instance(server: instance.server)
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    try await untilInStep(session, as: person)
    return session
  }

  private func rows(of page: UserPage) -> [Row] {
    page.items.map { Row(title: $0.row.title, claim: $0.claim) }
  }

  /// The standard family, with the active child's primary list holding three items: two of a scarf, one of which
  /// the relative claimed; a book that another giver claimed in full; and socks that are always wanted.
  private func childWithItems(on instance: Instance) async throws -> (StandardFamily, Fixture.Person) {
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let list = try await builder.primaryList(of: family.child)
    let scarf = try await builder.item("Scarf", on: list, as: family.child, quantity: 2)
    let book = try await builder.item("Book", on: list, as: family.child)
    _ = try await builder.item("Socks", on: list, as: family.child, isUnlimited: true)
    let aunt = try await builder.person("Avery")
    _ = try await builder.group("Aunts", users: [aunt, family.child])
    _ = try await builder.claim(scarf, as: family.relative, for: family.groupOccasion)
    _ = try await builder.claim(book, as: aunt)
    return (family, aunt)
  }

  @Test("A giver gets the person's items with still wanted and their own claim, and no item claimed in full")
  func giver() async throws {
    let instance = try await Instance()
    let (family, _) = try await childWithItems(on: instance)
    let session = try await signedIn(as: family.relative, on: instance)

    let page = try #require(session.userPage(id: family.child.id))
    #expect(!page.isOwn)
    #expect(page.notice == nil)
    #expect(!page.seesClaimsAsParent)
    #expect(
      rows(of: page) == [
        Row(title: "Scarf", claim: UserPage.Claim(stillWanted: 1, quantity: 2, youClaimed: 1)),
        Row(title: "Socks", claim: UserPage.Claim(stillWanted: nil, quantity: 1, youClaimed: 0)),
      ])
    #expect(page.primaryList?.canEdit == false)
  }

  @Test("The user's own page, the view of the list's recipient, has no claim state")
  func ownPage() async throws {
    let instance = try await Instance()
    let (family, _) = try await childWithItems(on: instance)
    let session = try await signedIn(as: family.child, on: instance)

    let page = try #require(session.userPage(id: family.child.id))
    #expect(page.isOwn)
    #expect(page.notice == nil)
    #expect(!page.seesClaimsAsParent)
    // The recipient's copy has every item, the claimed ones too, and none of their claim state.
    #expect(
      rows(of: page) == [
        Row(title: "Scarf", claim: nil), Row(title: "Book", claim: nil), Row(title: "Socks", claim: nil),
      ])
    #expect(page.items.allSatisfy { $0.row.stillWanted.isHidden && $0.row.myClaimedQuantity.isHidden })
  }

  @Test("A parent who is not a recipient gets the edit controls, the claim state, and the line that says why")
  func parentWhoIsNotARecipient() async throws {
    let instance = try await Instance()
    let (family, _) = try await childWithItems(on: instance)
    let session = try await signedIn(as: family.parent, on: instance)

    let page = try #require(session.userPage(id: family.child.id))
    #expect(page.seesClaimsAsParent)
    #expect(page.notice == nil)
    #expect(page.primaryList?.canEdit == true)
    #expect(
      rows(of: page) == [
        Row(title: "Scarf", claim: UserPage.Claim(stillWanted: 1, quantity: 2, youClaimed: 0)),
        Row(title: "Socks", claim: UserPage.Claim(stillWanted: nil, quantity: 1, youClaimed: 0)),
      ])
  }

  @Test("A parent gets the deactivated child's line and \"Deactivated\", and the items read-only")
  func deactivatedChild() async throws {
    let instance = try await Instance()
    let family = try await instance.builder.standardFamily()
    let session = try await signedIn(as: family.parent, on: instance)

    let page = try #require(session.userPage(id: family.deactivatedChild.id))
    #expect(page.user.isDeactivated)
    #expect(page.notice == .deactivatedChild)
    #expect(page.seesClaimsAsParent)
    #expect(page.primaryList?.id == family.primaryList.id)
    #expect(page.primaryList?.canEdit == false)
    // The given gift's item left the list at its reveal.
    #expect(
      rows(of: page) == [Row(title: "Kite", claim: UserPage.Claim(stillWanted: 1, quantity: 1, youClaimed: 0))])
  }

  @Test("The admin gets the admin's-access line, and no items, for a user they see only that way")
  func adminAccess() async throws {
    // The admin sees every user and group of the instance, so the test has a server of its own.
    let instance = try await Instance(server: try await TestServer.start())
    let family = try await instance.builder.standardFamily()
    let session = try await signedIn(as: family.admin, on: instance)

    let page = try #require(session.userPage(id: family.outsider.id))
    #expect(page.notice == .adminAccess)
    #expect(page.primaryList == nil)
    #expect(page.items.isEmpty)
    #expect(page.otherLists.isEmpty)
    #expect(!page.seesClaimsAsParent)

    // The admin's own page has no such line.
    #expect(try #require(session.userPage(id: family.admin.id)).notice == nil)
  }

  @Test("Other lists has the extra lists by name, with the server's item count, and is empty when there are none")
  func otherLists() async throws {
    let instance = try await Instance()
    let family = try await instance.builder.standardFamily()
    let parent = try await signedIn(as: family.parent, on: instance)

    let page = try #require(parent.userPage(id: family.deactivatedChild.id))
    #expect(page.otherLists.map(\.id) == [family.extraList.id, family.sharedList.id])
    #expect(page.otherLists.map(\.name) == [family.extraList.name, family.sharedList.name])
    #expect(page.otherLists.map(\.itemCount) == [1, 1])
    #expect(!page.otherLists.contains { $0.id == family.primaryList.id })

    let relative = try await signedIn(as: family.relative, on: instance)
    #expect(try #require(relative.userPage(id: family.relative.id)).otherLists.isEmpty)
  }

  @Test("A user who is not in the copy, or is in it only as a summary, gives the \"not found\" page")
  func notFound() async throws {
    let instance = try await Instance()
    let family = try await instance.builder.standardFamily()
    let session = try await signedIn(as: family.child, on: instance)

    // The child shares a list with their deactivated sibling, whom they get only as its recipient's summary.
    #expect(session.user(id: family.deactivatedChild.id)?.isSummary == true)
    #expect(session.userPage(id: family.deactivatedChild.id) == nil)
    #expect(session.userPage(id: family.outsider.id) == nil)
    #expect(session.userPage(id: "0") == nil)
  }

  @Test("A birthday with a year gives the age that the user is turning, and one with no year gives none")
  func birthday() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let ada = try await builder.person("Ada", birthday: (3, 4), birthYear: 2017)
    _ = try await builder.group("Friends", users: [ada, family.relative])
    let session = try await signedIn(as: family.relative, on: instance)

    // The device's zone is UTC.
    func day(_ text: String) throws -> Date { try Date(text + "T12:00:00Z", strategy: .iso8601) }
    let onTheDay = try #require(session.userPage(id: ada.id, today: try day("2026-03-04"))).birthday
    #expect(onTheDay == UserPage.Birthday(month: 3, day: 4, turning: 9))
    let after = try #require(session.userPage(id: ada.id, today: try day("2026-03-05"))).birthday
    #expect(after.turning == 10)
    let before = try #require(session.userPage(id: ada.id, today: try day("2026-01-10"))).birthday
    #expect(before.turning == 9)

    let robin = try #require(session.userPage(id: family.child.id)).birthday
    #expect(robin == UserPage.Birthday(month: 7, day: 21, turning: nil))
  }
}
