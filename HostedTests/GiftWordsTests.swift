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

  @Test(
    """
    A Given or Received heading names the occasion and its date, a Given row its day, and a Received row who gave it, \
    with the from label
    """
  )
  func givenAndReceived() throws {
    #expect(GiftWords.heading(occasionName: "Christmas", occasionDate: "2025-12-25") == "Christmas · Dec 25, 2025")
    #expect(GiftWords.heading(occasionName: nil, occasionDate: "2025-12-25") == "Dec 25, 2025")
    #expect(GiftWords.heading(occasionName: "", occasionDate: "2025-12-25") == "Dec 25, 2025")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let boxingDay = try #require(calendar.date(from: DateComponents(year: 2025, month: 12, day: 26, hour: 12)))
    #expect(GiftWords.given(boxingDay) == "Given Dec 26, 2025")
    #expect(GiftWords.givenBy(fromLabel: "Emma", giver: "Mom") == "From Emma · claimed by Mom")
    #expect(GiftWords.givenBy(fromLabel: nil, giver: "Mom") == "Mom")
    #expect(GiftWords.givenBy(fromLabel: "", giver: "Mom") == "Mom")
    #expect(GiftsPart.allCases.map(\.name) == ["Giving", "Given", "Received"])
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

  @Test("The Occasion menu names whose each occasion is, and Get another has its full words")
  func occasions() {
    #expect(GiftWords.pickable(kind: .birthday, name: "Birthday", person: "Morgan") == "Morgan's birthday")
    #expect(GiftWords.pickable(kind: .custom, name: "Recital", person: "Morgan") == "Morgan's Recital")
    #expect(GiftWords.pickable(kind: .shared, name: "Holiday", person: nil) == "Holiday")
    #expect(GiftWords.pickable(kind: .custom, name: "Recital", person: nil) == "Recital")
    #expect(GiftWords.getAnother == "Get another for a different occasion")
  }
}
