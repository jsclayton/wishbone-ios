import Foundation

/// The words for an item's price on a row: the price, or the range, in the server's currency, in the device's
/// locale. See "Languages" in `docs/spec.md`: a price keeps the server's currency.
///
/// A price is an integer in the currency's minor unit (ISO 4217): cents for USD and EUR, yen for JPY. A row shows a
/// whole amount with no minor digits, as the web app's rows do: "$20", "$19.99", "¥1,200".
public enum PriceWords {
  /// The price, or the range from the price up to the top price. Nil when the item has no price.
  public static func row(
    priceMinor: Int?, topPriceMinor: Int?, currency: String?, locale: Locale = .current
  ) -> String? {
    guard let priceMinor, let currency else { return nil }
    let low = amount(priceMinor, currency: currency, locale: locale)
    guard let topPriceMinor else { return low }
    let high = amount(topPriceMinor, currency: currency, locale: locale)
    return String(localized: "\(low)–\(high)", bundle: #bundle, locale: locale, comment: "A price range on a row")
  }

  /// The price, or the range, as an item's page shows it: "$20 to $35". Nil when the item has no price.
  public static func page(
    priceMinor: Int?, topPriceMinor: Int?, currency: String?, locale: Locale = .current
  ) -> String? {
    guard let priceMinor, let currency else { return nil }
    let low = amount(priceMinor, currency: currency, locale: locale)
    guard let topPriceMinor else { return low }
    let high = amount(topPriceMinor, currency: currency, locale: locale)
    return String(
      localized: "\(low) to \(high)", bundle: #bundle, locale: locale, comment: "A price range on an item's page")
  }

  /// The price of a store link: "$24.99". Nil when the link has no price.
  public static func storeLink(priceMinor: Int?, currency: String?, locale: Locale = .current) -> String? {
    guard let priceMinor, let currency else { return nil }
    return amount(priceMinor, currency: currency, locale: locale)
  }

  /// One amount in the currency, short.
  static func amount(_ minor: Int, currency: String, locale: Locale) -> String {
    let digits = fractionDigits(of: currency, locale: locale)
    let unit = (0..<digits).reduce(1) { value, _ in value * 10 }
    let value = Decimal(minor) / Decimal(unit)
    let shown = minor % unit == 0 ? 0 : digits
    return value.formatted(.currency(code: currency).locale(locale).precision(.fractionLength(shown)))
  }

  /// How many minor digits the currency has: 2 for USD, 0 for JPY.
  private static func fractionDigits(of currency: String, locale: Locale) -> Int {
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .currency
    formatter.currencyCode = currency
    return formatter.maximumFractionDigits
  }
}
