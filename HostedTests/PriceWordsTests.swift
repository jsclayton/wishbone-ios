import Foundation
import Testing
import WishboneUI

/// The words for an item's price on a row, on its page, and on a store link: a price, a range, or none, in the
/// server's currency, in the device's locale. See "Languages" in `docs/spec.md`.
@Suite("The price words", .timeLimit(.minutes(1)))
@MainActor
struct PriceWordsTests {
  private let english = Locale(identifier: "en_US")

  private func words(_ price: Int?, _ top: Int? = nil, _ currency: String? = "USD", locale: Locale? = nil) -> String? {
    PriceWords.row(priceMinor: price, topPriceMinor: top, currency: currency, locale: locale ?? english)
  }

  @Test("A price, with minor digits only when it has some")
  func price() {
    #expect(words(1999) == "$19.99")
    #expect(words(2000) == "$20")
    #expect(words(5) == "$0.05")
  }

  @Test("A range, from the price to the top price")
  func range() {
    #expect(words(1000, 2550) == "$10–$25.50")
  }

  @Test("No price, or no currency, gives no words")
  func noPrice() {
    #expect(words(nil) == nil)
    #expect(words(nil, 2000) == nil)
    #expect(words(1000, nil, nil) == nil)
  }

  @Test("The server's currency is kept, in the device's locale, with the currency's own minor unit")
  func currencyKept() {
    #expect(words(1500, nil, "EUR") == "€15")
    #expect(words(1200, nil, "JPY") == "¥1,200")
    #expect(words(1234, nil, "KWD")?.contains("1.234") == true)
    #expect(words(1999, nil, "GBP", locale: Locale(identifier: "de_DE")) == "19,99\u{a0}£")
  }

  @Test("An item's page gives a range in words, \"$20 to $35\", and a price alone as on a row")
  func page() {
    #expect(PriceWords.page(priceMinor: 2000, topPriceMinor: 3500, currency: "USD", locale: english) == "$20 to $35")
    #expect(PriceWords.page(priceMinor: 1999, topPriceMinor: nil, currency: "USD", locale: english) == "$19.99")
    #expect(PriceWords.page(priceMinor: nil, topPriceMinor: 3500, currency: "USD", locale: english) == nil)
    #expect(PriceWords.page(priceMinor: 2000, topPriceMinor: nil, currency: nil, locale: english) == nil)
  }

  @Test("A store link's price is one amount in the server's currency, and none with no price")
  func storeLink() {
    #expect(PriceWords.storeLink(priceMinor: 2499, currency: "USD", locale: english) == "$24.99")
    #expect(PriceWords.storeLink(priceMinor: 1200, currency: "JPY", locale: english) == "¥1,200")
    #expect(PriceWords.storeLink(priceMinor: nil, currency: "USD", locale: english) == nil)
    #expect(PriceWords.storeLink(priceMinor: 2499, currency: nil, locale: english) == nil)
  }
}
