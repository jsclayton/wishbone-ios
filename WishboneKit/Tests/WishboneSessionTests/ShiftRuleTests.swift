import Testing
import WishboneSession

/// The server's shift rule for a move, which is pure: the other items' places and the move go in, and their new
/// places come out. See "What the windows show after a drop" in `docs/spec.md`. `MoveTests` holds it against the
/// real server.
@Suite("The shift rule", .timeLimit(.minutes(1)))
struct ShiftRuleTests {
  private func place(_ id: String, _ listID: String, _ position: Int) -> ShiftRule.Place {
    ShiftRule.Place(id: id, listID: listID, position: position)
  }

  /// The positions of the items on the list, by ID, in the order given.
  private func positions(_ places: [ShiftRule.Place], on listID: String) -> [String: Int] {
    Dictionary(uniqueKeysWithValues: places.filter { $0.listID == listID }.map { ($0.id, $0.position) })
  }

  @Test("A move to the end of another list closes the gap on the old list, and leaves the new list's items")
  func toTheEnd() {
    let others = [
      place("a", "old", 0), place("c", "old", 2), place("d", "old", 3), place("e", "new", 0), place("f", "new", 1),
    ]
    let shifted = ShiftRule.shifting(others, moving: place("b", "old", 1), to: place("b", "new", 2))
    #expect(shifted.map(\.id) == ["a", "c", "d", "e", "f"])
    #expect(positions(shifted, on: "old") == ["a": 0, "c": 1, "d": 2])
    #expect(positions(shifted, on: "new") == ["e": 0, "f": 1])
  }

  @Test("A move to a place on another list closes the gap on the old list, and shifts the items from that place on")
  func toAPlace() {
    let others = [
      place("a", "old", 0), place("c", "old", 2), place("e", "new", 0), place("f", "new", 1), place("g", "new", 2),
    ]
    let shifted = ShiftRule.shifting(others, moving: place("b", "old", 1), to: place("b", "new", 1))
    #expect(positions(shifted, on: "old") == ["a": 0, "c": 1])
    #expect(positions(shifted, on: "new") == ["e": 0, "f": 2, "g": 3])
  }

  @Test("The items of other lists stay, and a list with a gap that the viewer can't see shifts as the server's does")
  func otherListsStay() {
    // The viewer doesn't see the item at 1 on the old list: a fully claimed item, for a parent who is a giver.
    let others = [place("a", "old", 0), place("c", "old", 3), place("x", "other", 0), place("y", "other", 5)]
    let shifted = ShiftRule.shifting(others, moving: place("b", "old", 2), to: place("b", "new", 0))
    #expect(positions(shifted, on: "old") == ["a": 0, "c": 2])
    #expect(positions(shifted, on: "other") == ["x": 0, "y": 5])
  }

  @Test("On one list, the rule is the server's reorder, up and down")
  func reorder() {
    let others = [place("a", "l", 0), place("b", "l", 1), place("d", "l", 3), place("e", "l", 4)]
    // c from 2 to 0: the items before its old place go down one.
    let up = ShiftRule.shifting(others, moving: place("c", "l", 2), to: place("c", "l", 0))
    #expect(positions(up, on: "l") == ["a": 1, "b": 2, "d": 3, "e": 4])
    // c from 2 to 4: the items after its old place, up to its new one, go up one.
    let down = ShiftRule.shifting(others, moving: place("c", "l", 2), to: place("c", "l", 4))
    #expect(positions(down, on: "l") == ["a": 0, "b": 1, "d": 2, "e": 3])
    // In place: nothing moves.
    let still = ShiftRule.shifting(others, moving: place("c", "l", 2), to: place("c", "l", 2))
    #expect(still == others)
  }
}
