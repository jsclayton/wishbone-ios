import Foundation
import Testing
import WishboneAPI
import WishboneSession
import WishboneUI

/// The words of the Gifts tab: each flag of a Giving row, as the app says it. See "Words" in
/// `docs/screens/gifts.md`.
@Suite("The words of the Gifts tab", .timeLimit(.minutes(1)))
@MainActor
struct GiftWordsTests {
  @Test(
    """
    Each flag has its words, with the names that the giver can see, and its words without them, and a heading names \
    the recipients and the occasion
    """
  )
  func flags() throws {
    let table: [(GivingGift.Flag, String)] = [
      (.changed, "The item changed"),
      (.removed, "Removed from the list"),
      (.moved(toList: "Toys"), "Moved to Toys"),
      (.moved(toList: nil), "Moved to another list"),
      (.occasionMoved(to: "Christmas"), "Now for Christmas"),
      (.occasionMoved(to: nil), "Moved to another occasion"),
      (.noLongerShared, "No longer shared with you"),
      (.restored(by: "Mom"), "Mom says they didn't get this"),
      (.restored(by: nil), "Marked as not received"),
      (.recipientsChanged(to: ["Mom"]), "Now for Mom"),
      (.recipientsChanged(to: ["Mom", "Dad"]), "Now for Mom and Dad"),
      (.recipientsChanged(to: []), "The recipients changed"),
      (.recipientsChanged(to: nil), "The recipients changed"),
    ]
    for (flag, words) in table {
      #expect(GiftWords.flag(flag) == words, "\(flag)")
    }

    // The row's other words, and the tab's.
    #expect(GiftWords.needsAttention == "Needs attention")
    #expect(GiftWords.howMany(3) == "3 of these")
    #expect(GiftWords.from("Emma") == "From Emma")
    #expect(GiftWords.bought(true) == "Bought")
    #expect(GiftWords.bought(false) == "Not bought")
    #expect(GiftWords.tab(badge: 1) == "Gifts, 1 needs attention")
    #expect(GiftWords.tab(badge: 2) == "Gifts, 2 need attention")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let boxingDay = try #require(calendar.date(from: DateComponents(year: 2026, month: 12, day: 26, hour: 12)))
    #expect(GiftWords.hiddenUntil(boxingDay) == "Hidden until Dec 26")
    #expect(GiftWords.occasion(.hiddenUntil(boxingDay)) == "Hidden until Dec 26")
    #expect(GiftWords.occasion(.named("Christmas")) == "Christmas")

    // A Giving heading: the recipients and the occasion, or only the occasion when the giver can't see the list.
    #expect(GiftWords.heading(recipients: ["Mom"], occasion: .named("Christmas")) == "For Mom · Christmas")
    #expect(
      GiftWords.heading(recipients: ["Mom", "Dad"], occasion: .hiddenUntil(boxingDay))
        == "For Mom and Dad · Hidden until Dec 26")
    #expect(GiftWords.heading(recipients: nil, occasion: .named("Christmas")) == "Christmas")
    #expect(GiftWords.heading(recipients: [], occasion: .hiddenUntil(boxingDay)) == "Hidden until Dec 26")
  }

  @Test("A raise that didn't raise says why in place, and the stepper says when it can't go higher")
  func raise() throws {
    let address = try #require(InstanceAddress("https://wishbone.example.com"))
    #expect(GiftWords.raiseResult(of: .raised, address: address) == nil)
    #expect(GiftWords.raiseResult(of: .notOffered, address: address) == nil)
    #expect(
      GiftWords.raiseResult(of: .unreachable, address: address)
        == "Can't reach https://wishbone.example.com. The number didn't change.")
    #expect(GiftWords.raiseResult(of: .someoneElseGotIt, address: address) == "Someone else just got this.")
    let notAllowed = APIError.Refusal(
      route: .updateGift, status: 403, code: .quantityRaiseNotAllowed, detail: "The server's words")
    #expect(
      GiftWords.raiseResult(of: .refused(notAllowed), address: address)
        == "You can only lower how many, because this list is now for you too.")
    #expect(GiftWords.howManyValue(2, canRaise: true) == "2")
    #expect(GiftWords.howManyValue(2, canRaise: false) == "2, can't go higher")
  }

  @Test("I won't get this, its confirmation, and the answers to a flag")
  func answers() {
    #expect(GiftWords.wontGetThis == "I won't get this")
    #expect(GiftWords.wontGetThisQuestion("Kite") == "You won't get Kite?")
    #expect(GiftWords.wontGetThisMessage == "Other people can then claim it.")
    #expect(GiftWords.answer(to: .removed) == "Keep it")
    #expect(GiftWords.answer(to: .changed) == "OK")
    #expect(GiftWords.answer(to: .moved(toList: nil)) == "OK")
    #expect(GiftWords.answer(to: .noLongerShared) == "OK")
  }
}
