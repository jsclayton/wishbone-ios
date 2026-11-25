import Foundation
import Testing

@testable import WishboneAPI
@testable import WishboneSession

/// An answer in flight wins over a pull for the same thing, in the copy itself: a pull's change puts back what an
/// answer saved or removed after the pull's mark, and nothing more. See "Unsent changes" in `docs/spec.md`, and
/// `Answers.swift`. The tests of each write that waits for the server hold the same against the real server.
@Suite("An answer in flight wins over a pull", .timeLimit(.minutes(1)))
struct AnswersTests {
  /// A blocked store, as the server gives it.
  private func store(_ name: String, version: String = "\"1\"") throws -> Versioned<BlockedStore> {
    let body = #"{"id":"\#(name)","store":"\#(name).example","created_at":"2026-11-25T10:00:00Z","can_delete":true}"#
    return Versioned(resource: try JSONDecoder().decode(BlockedStore.self, from: Data(body.utf8)), version: version)
  }

  private func stores(in database: LocalDatabase) async throws -> [String] {
    try await database.snapshot(ofUser: "me").blockedStores.map(\.id).sorted()
  }

  @Test("A pull keeps what an answer saved or removed after its mark, and the next pull is the authority again")
  func afterTheMark() async throws {
    let database = try LocalDatabase.inMemory()
    try await database.replaceBlockedStores(with: [try store("kept")])
    // An answer before the pull's mark: the pull's answer is newer, and wins.
    try await database.saveBlockedStore(try store("early"))

    let pull = database.keepingAnswers(after: database.answers.mark())
    // Two answers after the mark: one saves a store, and one removes a store.
    try await database.saveBlockedStore(try store("late"))
    try await database.removeBlockedStore("kept")

    // The pull's answer is older than both.
    try await pull.replaceBlockedStores(with: [try store("kept"), try store("other")])
    #expect(try await stores(in: database) == ["late", "other"])

    // A later change of the same pull keeps them too.
    try await pull.replaceBlockedStores(with: [try store("kept"), try store("other"), try store("more")])
    #expect(try await stores(in: database) == ["late", "more", "other"])

    // The next pull takes its mark after the answers. Its answer is the server's word.
    let next = database.keepingAnswers(after: database.answers.mark())
    try await next.replaceBlockedStores(with: [try store("kept")])
    #expect(try await stores(in: database) == ["kept"])
  }

  @Test("A change that is no pull's takes no mark: an answer never keeps a row from it")
  func noMark() async throws {
    let database = try LocalDatabase.inMemory()
    try await database.saveBlockedStore(try store("late"))
    try await database.replaceBlockedStores(with: [])
    #expect(try await stores(in: database).isEmpty)
  }

  @Test("The rows that answers came for are numbered in order, and a mark sees only the later ones")
  func marks() {
    let answers = Answers()
    let first = Answers.Rows.row("a", of: GiftRow.self)
    let second = Answers.Rows.storeLinks(ofItem: "b")
    answers.note([first])
    let mark = answers.mark()
    #expect(answers.rows(after: mark).isEmpty)
    answers.note([second])
    #expect(answers.rows(after: mark) == [second])
    // The same rows again, in a later answer: they count from the later one.
    answers.note([first])
    #expect(Set(answers.rows(after: mark)) == [first, second])
    #expect(answers.rows(after: answers.mark()).isEmpty)
    // A change that names no rows is no answer.
    let before = answers.mark()
    answers.note([])
    #expect(answers.mark() == before)
  }
}
