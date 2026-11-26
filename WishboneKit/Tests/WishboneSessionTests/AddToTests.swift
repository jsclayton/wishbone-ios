import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// Which list an add goes to, and the duplicate hint, at the session model's seam, against the real server: Add to
/// in the add form, a list's own Add item row with its form fixed to the list, and "Already on this list: {title}".
/// See "Which list", "The add form is pushed onto the Add screen", "After Add", "Whose list: name the recipient",
/// and "What the add form holds" in `docs/spec.md`, and `docs/screens/add-form.md`.
@Suite("Add to and the duplicate hint", .timeLimit(.minutes(2)))
@MainActor
struct AddToTests {
  /// A new device, signed in as the person. Its first sync has ended, and the session publishes all that it wrote.
  /// The session reaches the server through the instance's conditioner, so the test keeps the instance.
  private func signedIn(as person: Fixture.Person, on instance: Instance) async throws -> SessionModel {
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    try await untilInStep(session, as: person)
    return session
  }

  /// An add that ended with the item added.
  private func added(_ outcome: AddOutcome, sourceLocation: SourceLocation = #_sourceLocation) throws -> AddedItem {
    guard case .added(let item) = outcome else {
      Issue.record("The add ended with \(outcome)", sourceLocation: sourceLocation)
      throw CancellationError()
    }
    return item
  }

  /// The form for typed words, as the Add screen gives it after "Fill it in myself".
  private func form(_ words: String, state: inout AddScreenState) throws -> ItemDraft {
    state.text = words
    let draft = state.fillItInMyself()
    return try #require(draft)
  }

  /// The search of the text, as the Add screen starts it and takes its answer: the form to push.
  private func search(_ text: String, in session: SessionModel, state: inout AddScreenState) async throws
    -> ItemDraft
  {
    state.text = text
    let start = state.startSearch()
    let started = try #require(start)
    let outcome = await session.search(started.input)
    let draft = state.searchEnded(started.id, with: outcome)
    return try #require(draft)
  }

  @Test(
    "Add to has the lists the user can edit, in the Lists tab's order, each child's under the child, with recipients' names where the user is not one"
  )
  func listsTheUserCanEdit() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let family = try await builder.standardFamily()
    let zebra = try await builder.list("Zebra", of: family.parent)
    let books = try await builder.list("Books", of: family.child)
    let parentPrimary = try await builder.primaryList(of: family.parent)
    let childPrimary = try await builder.primaryList(of: family.child)

    let session = try await signedIn(as: family.parent, on: instance)
    var state = AddScreenState()
    let draft = try form("Kite", state: &state)
    let addTo = try #require(session.addTo(for: draft))

    #expect(addTo.yourLists.map(\.id) == [parentPrimary.id, family.parentList.id, zebra.id])
    #expect(addTo.yourLists.allSatisfy { $0.isMine && $0.recipientNames.isEmpty })
    // The deactivated child's lists can't be edited, but the list that the two children share can. It is offered
    // once, under the first child, so the deactivated child has no part.
    #expect(addTo.children.map(\.child.id) == [family.child.id])
    let part = try #require(addTo.children.first)
    #expect(part.targets.map(\.id) == [childPrimary.id, books.id, family.sharedList.id])
    #expect(part.targets.allSatisfy { !$0.isMine })
    #expect(part.targets[0].recipientNames == [family.child.name])
    #expect(Set(part.targets[2].recipientNames) == [family.child.name, family.deactivatedChild.name])
    // Every list offered is one the user can edit, and no other list that the user can edit is left out.
    let offered = addTo.targets.map(\.id)
    #expect(offered.allSatisfy { session.list(id: $0)?.canEdit == true })
    #expect(Set(offered) == Set(session.lists.filter(\.canEdit).map(\.id)))
    #expect(!offered.contains(family.primaryList.id))
    #expect(!offered.contains(family.extraList.id))
  }

  @Test("Add to is hidden for a user who can edit one list, and shows with a second list")
  func hiddenWithOneList() async throws {
    let instance = try await Instance()
    let person = try await instance.builder.person("Robin")
    let session = try await signedIn(as: person, on: instance)
    var state = AddScreenState()
    let draft = try form("Kite", state: &state)

    let primary = try #require(session.primaryList)
    #expect(session.addTo(for: draft) == nil)
    #expect(session.target(of: draft)?.id == primary.id)

    let extra = try await instance.builder.list("Camping", of: person)
    _ = await session.syncNow()
    await until { session.list(id: extra.id) != nil }
    #expect(session.addTo(for: draft)?.targets.map(\.id) == [primary.id, extra.id])
  }

  @Test("A second add starts on the primary list again")
  func secondAddStartsOnThePrimaryList() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let parent = try await builder.person("Morgan")
    let child = try await builder.person("Robin", parents: [parent])
    let childPrimary = try await builder.primaryList(of: child)
    let session = try await signedIn(as: parent, on: instance)
    var state = AddScreenState()

    var first = try form("Kite", state: &state)
    #expect(first.listID == nil)
    #expect(session.target(of: first)?.id == session.primaryList?.id)
    first.listID = childPrimary.id
    let target = try #require(session.target(of: first))
    #expect(target.recipientNames == [child.name])
    let item = try added(await session.add(&first))
    #expect(item.listName == childPrimary.name)
    state.didAdd(item)
    let saved = try await parent.signedIn().get("/items/\(item.id)")
    #expect(saved["list_id"].string == childPrimary.id)

    // No earlier choice is remembered.
    let second = try form("Ball", state: &state)
    #expect(second.listID == nil)
    #expect(session.target(of: second)?.id == session.primaryList?.id)
    var again = second
    let next = try added(await session.add(&again))
    #expect(next.listName == session.primaryList?.name)
  }

  @Test("A list's Add item row gives a form fixed to that list, and the item lands at the end of that list")
  func fixedToTheList() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let person = try await builder.person("Robin")
    let camping = try await builder.list("Camping", of: person)
    _ = try await builder.item("Tent", on: camping, as: person)
    _ = try await builder.item("Stove", on: camping, as: person)
    let session = try await signedIn(as: person, on: instance)

    for title in ["Lantern", "Rope"] {
      var state = AddScreenState(fixedTo: camping.id)
      var draft = try form(title, state: &state)
      #expect(draft.listID == camping.id)
      #expect(draft.isFixedToList)
      // The form offers no choice: Add to is hidden.
      #expect(session.addTo(for: draft) == nil)
      #expect(session.target(of: draft)?.id == camping.id)

      let item = try added(await session.add(&draft))
      #expect(item.listName == camping.name)
      await until { session.items(onList: camping.id).last?.id == item.id }
    }
    #expect(session.items(onList: camping.id).map(\.title) == ["Tent", "Stove", "Lantern", "Rope"])
    let primary = try #require(session.primaryList)
    #expect(session.items(onList: primary.id).isEmpty)

    // Blank forms and filled-in forms from the sheet are fixed too.
    var state = AddScreenState(fixedTo: camping.id)
    #expect(state.addWithoutTheLink().listID == camping.id)
  }

  @Test("The hint shows for the same store link, as POST /search returns it")
  func hintForTheSameLink() async throws {
    let instance = try await Instance()
    let page = try await StorePage(title: "Lantern \(instance.builder.tag)", priceMinor: 1800)
    let person = try await instance.builder.person("Robin")
    let session = try await signedIn(as: person, on: instance)
    var state = AddScreenState()

    var first = try await search(page.url.absoluteString, in: session, state: &state)
    #expect(session.duplicateHint(for: first) == nil)
    let item = try added(await session.add(&first))
    state.didAdd(item)
    await until { session.item(id: item.id) != nil }

    var second = try await search(page.url.absoluteString, in: session, state: &state)
    // Only the link matches: the title is another.
    second.title = "Something else"
    let hint = try #require(session.duplicateHint(for: second))
    #expect(hint.itemID == item.id)
    #expect(hint.title == page.title)
    // On the Add screen, it opens the item.
    #expect(hint.opensItem)
  }

  @Test("The hint shows for the same title, with case and extra spaces ignored")
  func hintForTheSameTitle() async throws {
    let instance = try await Instance()
    let person = try await instance.person("Robin", items: ["Lego  Castle"])
    let session = try await signedIn(as: person, on: instance)
    var state = AddScreenState()

    var draft = try form("  lego castle ", state: &state)
    let hint = try #require(session.duplicateHint(for: draft))
    #expect(hint.title == "Lego  Castle")
    #expect(session.item(id: hint.itemID)?.title == "Lego  Castle")

    draft.title = "LEGO\tcastle"
    #expect(session.duplicateHint(for: draft)?.itemID == hint.itemID)
    draft.title = "Lego Castles"
    #expect(session.duplicateHint(for: draft) == nil)
    draft.title = "   "
    #expect(session.duplicateHint(for: draft) == nil)
  }

  @Test("The hint follows the list picked, and the add still works")
  func hintFollowsTheList() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let person = try await builder.person("Robin")
    let camping = try await builder.list("Camping", of: person)
    let tent = try await builder.item("Tent", on: camping, as: person)
    let session = try await signedIn(as: person, on: instance)
    var state = AddScreenState()

    var draft = try form("Tent", state: &state)
    // The primary list has no tent.
    #expect(session.duplicateHint(for: draft) == nil)
    draft.listID = camping.id
    #expect(session.duplicateHint(for: draft)?.itemID == tent.id)
    draft.listID = session.primaryList?.id
    #expect(session.duplicateHint(for: draft) == nil)

    // The hint never blocks the add: a second tent goes on Camping.
    draft.listID = camping.id
    let item = try added(await session.add(&draft))
    #expect(item.listName == camping.name)
    await until { session.items(onList: camping.id).count == 2 }
    #expect(session.items(onList: camping.id).map(\.title) == ["Tent", "Tent"])
  }

  @Test("In a sheet, the hint opens nothing")
  func hintInASheetOpensNothing() async throws {
    let instance = try await Instance()
    let person = try await instance.person("Robin", items: ["Kite"])
    let session = try await signedIn(as: person, on: instance)
    let primary = try #require(session.primaryList)
    var state = AddScreenState(fixedTo: primary.id)

    let draft = try form("Kite", state: &state)
    let hint = try #require(session.duplicateHint(for: draft))
    #expect(hint.title == "Kite")
    #expect(!hint.opensItem)
  }

  @Test("A parent who is a giver on a child's list gets no hint for a fully claimed item")
  func noHintForAFullyClaimedItem() async throws {
    let instance = try await Instance()
    let builder = instance.builder
    let parent = try await builder.person("Morgan")
    let child = try await builder.person("Robin", parents: [parent])
    let aunt = try await builder.person("Jordan")
    _ = try await builder.group("Family", users: [parent, child, aunt])
    let childPrimary = try await builder.primaryList(of: child)
    let bike = try await builder.item("Bike", on: childPrimary, as: child)
    let ball = try await builder.item("Ball", on: childPrimary, as: child)
    _ = try await builder.claim(bike, as: aunt)
    let session = try await signedIn(as: parent, on: instance)
    var state = AddScreenState(fixedTo: childPrimary.id)

    // The parent edits the list, as a giver: the server hides the claimed bike, so the hint is silent.
    #expect(session.list(id: childPrimary.id)?.canEdit == true)
    #expect(session.item(id: bike.id) == nil)
    let bikeForm = try form("Bike", state: &state)
    #expect(session.duplicateHint(for: bikeForm) == nil)
    // An item that the parent sees gets the hint.
    let ballForm = try form("Ball", state: &state)
    #expect(session.duplicateHint(for: ballForm)?.itemID == ball.id)
  }
}
