import Foundation
import Testing
import WishboneSession
import WishboneUI

/// The words of the Gifts tab: each flag of a Giving row, as the app says it. See "Words" in
/// `docs/screens/gifts.md`.
@Suite("The words of the Gifts tab", .timeLimit(.minutes(1)))
@MainActor
struct GiftWordsTests {
  @Test("Each flag has its words, with the names that the giver can see, and its words without them")
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
  }
}
