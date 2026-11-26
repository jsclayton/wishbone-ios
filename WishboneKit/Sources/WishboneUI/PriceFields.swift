import SwiftUI

/// Price and Up to, in the currency's main unit, side by side, and stacked at the largest text sizes. The add form
/// and the Edit item sheet have them. A field that is emptied clears its price.
struct PriceFields: View {
  @Binding var priceMinor: Int?

  /// The top of a price range.
  @Binding var topPriceMinor: Int?

  /// The price's ISO 4217 code.
  let currency: String

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    let layout =
      dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
    layout {
      field($priceMinor, label: Text("Price", bundle: #bundle))
      field($topPriceMinor, label: Text("Up to", bundle: #bundle))
    }
  }

  private func field(_ minor: Binding<Int?>, label: Text) -> some View {
    TextField(value: price(minor), format: .currency(code: currency)) {
      label
    }
    #if os(iOS)
      .keyboardType(.decimalPad)
    #endif
  }

  /// A price in the currency's main unit, for a field: "24.99" for 2499 cents.
  private func price(_ minor: Binding<Int?>) -> Binding<Decimal?> {
    let unit = Decimal(minorUnit)
    return Binding {
      minor.wrappedValue.map { Decimal($0) / unit }
    } set: { value in
      minor.wrappedValue = value.map { value in
        var minor = value * unit
        var rounded = Decimal()
        NSDecimalRound(&rounded, &minor, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
      }
    }
  }

  /// How many minor units the currency has in its main unit: 100 for USD, 1 for JPY.
  private var minorUnit: Int {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = currency
    return (0..<formatter.maximumFractionDigits).reduce(1) { value, _ in value * 10 }
  }
}
