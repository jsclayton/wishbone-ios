import Foundation

/// A store's product page on this machine, for a search to read: a title, a price, images, and options. The test
/// server reads pages and downloads images on this machine (`WISHBONE_EXTRACT_ALLOW_PRIVATE`), so a link to the
/// page reads as a real store's does. Its store is `127.0.0.1`.
///
/// It is two network conditioners: the store, which answers every request itself, and one in front of it, which
/// a test can hold the page at, as at a slow store. A conditioner's hold sends the request on after its release,
/// so the one that holds is not the one that answers. It stops when its last holder goes.
public final class StorePage: Sendable {
  /// An option that the page lists, such as a size, with the one that it picks.
  public struct Option: Sendable {
    public let name: String
    public let values: [String]
    public let selected: String?

    public init(_ name: String, values: [String], selected: String? = nil) {
      self.name = name
      self.values = values
      self.selected = selected
    }
  }

  public let title: String

  /// The price in cents, in USD.
  public let priceMinor: Int

  /// The page's address.
  public let url: URL

  /// The addresses of the page's images, best first.
  public let imageURLs: [URL]

  private let store: NetworkConditioner
  private let conditioner: NetworkConditioner
  private let route: NetworkConditioner.Route

  /// A page with `images` images, each a PNG of one pixel at an address of its own. With `isProduct` false, the
  /// page is a plain one with no title, no product, and no images, so a search reads nothing from it.
  public init(
    title: String, priceMinor: Int, images: Int = 2, options: [Option] = [], isProduct: Bool = true
  ) async throws {
    // Every request has a canned answer at the store, so the address behind it is never asked.
    let server = try await TestServer.shared()
    store = try await NetworkConditioner(to: server.address)
    conditioner = try await NetworkConditioner(to: store.address)
    self.title = title
    self.priceMinor = priceMinor
    let page = "/store/\(UUID().uuidString.lowercased())"
    route = .init("GET", page)
    let front = conditioner
    url = front.url(page)
    let images = isProduct ? images : 0
    imageURLs = (0..<images).map { front.url("\(page)-image-\($0).png") }
    for index in 0..<images {
      store.answer(
        .init("GET", "\(page)-image-\(index).png"),
        with: .init(status: 200, headers: ["Content-Type": "image/png"], body: FixtureBuilder.onePixelPNG))
    }
    let html =
      isProduct
      ? Self.html(title: title, priceMinor: priceMinor, images: imageURLs.map(\.absoluteString), options: options)
      : "<!doctype html>\n<html><body><p>Nothing to buy here.</p></body></html>"
    store.answer(
      route, with: .init(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(html.utf8)))
  }

  /// Holds the next read of the page until the test releases the hold.
  public func hold() -> NetworkConditioner.Hold {
    conditioner.hold(route, at: .request)
  }

  /// How many times the page was read.
  public var reads: Int {
    conditioner.requests.filter { $0.isOn(route) }.count
  }

  /// The page: a JSON-LD product with its name, images, and price, and a menu for each option, with a label.
  private static func html(title: String, priceMinor: Int, images: [String], options: [Option]) -> String {
    let cents = priceMinor % 100
    let price = "\(priceMinor / 100).\(cents < 10 ? "0" : "")\(cents)"
    let product: [String: Any] = [
      "@context": "https://schema.org", "@type": "Product", "name": title, "image": images,
      "offers": ["@type": "Offer", "price": price, "priceCurrency": "USD"],
    ]
    let json = (try? JSONSerialization.data(withJSONObject: product, options: [.sortedKeys])) ?? Data()
    let menus = options.enumerated().map { index, option in
      let values = option.values.map { value in
        "<option value=\"\(value)\"\(value == option.selected ? " selected" : "")>\(value)</option>"
      }
      return """
        <label for="option-\(index)">\(option.name)</label>
        <select id="option-\(index)" name="\(option.name.lowercased())">\(values.joined())</select>
        """
    }
    return """
      <!doctype html>
      <html><head><title>\(title)</title>
      <script type="application/ld+json">\(String(decoding: json, as: UTF8.self))</script>
      </head><body><h1>\(title)</h1>\(menus.joined(separator: "\n"))</body></html>
      """
  }
}
