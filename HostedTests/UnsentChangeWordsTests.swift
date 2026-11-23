import Foundation
import Testing
import WishboneAPI
import WishboneSession
import WishboneUI

/// The words of the unsent changes: the count on the line "Can't reach {address}", the warning before Sign out, the
/// actions of a Giving row, and the lines of the alert of late refusals. See "Unsent changes, sign-out, and late
/// refusals" and "Sign out" in `docs/spec.md`, and "Words" in `docs/screens/gifts.md`.
@Suite("The words of the unsent changes", .timeLimit(.minutes(1)))
@MainActor
struct UnsentChangeWordsTests {
  @Test("The line and the warning count the unsent changes, one and more than one")
  func counts() {
    #expect(CantReach.unsentChanges(1) == "1 change will be sent when it's back.")
    #expect(CantReach.unsentChanges(3) == "3 changes will be sent when it's back.")
    #expect(SignOutWords.warning(unsentChanges: 0) == "You need a new login link to sign in again.")
    #expect(
      SignOutWords.warning(unsentChanges: 1)
        == "You need a new login link to sign in again. 1 change hasn't been sent and will be lost.")
    #expect(
      SignOutWords.warning(unsentChanges: 2)
        == "You need a new login link to sign in again. 2 changes haven't been sent and will be lost.")
  }

  @Test("A Giving row's actions are Mark bought and Mark not bought")
  func actions() {
    #expect(GiftWords.markBought(true) == "Mark bought")
    #expect(GiftWords.markBought(false) == "Mark not bought")
  }

  @Test("Each late refusal is a line: what the change did, then the app's words for the server's code")
  func lateRefusals() {
    let forbidden = LateRefusal(
      id: 1, action: .markBought(giftID: "15", isBought: true), title: "Kite",
      refusal: .init(route: .updateGift, status: 403, code: .forbidden, detail: "The server's words"))
    let gone = LateRefusal(
      id: 2, action: .markBought(giftID: "16", isBought: false), title: "Ball",
      refusal: .init(route: .updateGift, status: 404, code: .notFound, detail: "The server's words"))
    #expect(LateRefusalWords.line(forbidden) == "Marking Kite bought: You can't do this any more.")
    #expect(LateRefusalWords.line(gone) == "Marking Ball not bought: This is gone, or it isn't shared with you.")
    #expect(
      LateRefusalWords.message([forbidden, gone])
        == """
        Marking Kite bought: You can't do this any more.
        Marking Ball not bought: This is gone, or it isn't shared with you.
        """)
  }
}
