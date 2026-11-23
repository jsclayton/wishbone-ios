import Foundation

// Search and the add: `POST /search` turns a link or typed words into what the add form shows, and
// `POST /lists/{id}/items` adds the item. See "Adding an item" in `docs/spec.md`, and the server spec's "Search".

/// The answer of `POST /search`. Today a search gives exactly one result.
struct SearchBody: Model {
  let results: [SearchResult]

  enum CodingKeys: String, CodingKey, CaseIterable {
    case results
  }

  static let fields = WishboneAPI.fields(of: CodingKeys.self, lists: ["results": SearchResult.fields])
}

/// What a search found. It saves nothing: the user checks it in the add form, then adds the item.
public struct SearchResult: Model, Equatable {
  /// The title, or nil. For typed words, the words as typed, cut to the longest title.
  public let title: String?

  /// For typed words, the words as typed, up to the longest notes. Otherwise nil.
  public let notes: String?

  /// Whether the typed words were longer than the longest notes.
  public let notesCut: Bool

  /// The item's price, or nil. For a link, the page's price is on the store link.
  public let priceMinor: Int?
  public let topPriceMinor: Int?

  /// An ISO 4217 code. Nil exactly when `priceMinor` is.
  public let currency: String?

  /// For a link, one store link. Otherwise empty.
  public let storeLinks: [SearchStoreLink]

  /// Up to 5 of the page's images, best first. Each is the store's own address, which loads with no token.
  public let imageURLs: [String]

  /// The page's options, at most 4.
  public let options: [SearchOption]

  /// False when nothing was read from the input: always for typed words.
  public let found: Bool

  public init(
    title: String?, notes: String? = nil, notesCut: Bool = false, priceMinor: Int? = nil,
    topPriceMinor: Int? = nil, currency: String? = nil, storeLinks: [SearchStoreLink] = [],
    imageURLs: [String] = [], options: [SearchOption] = [], found: Bool
  ) {
    self.title = title
    self.notes = notes
    self.notesCut = notesCut
    self.priceMinor = priceMinor
    self.topPriceMinor = topPriceMinor
    self.currency = currency
    self.storeLinks = storeLinks
    self.imageURLs = imageURLs
    self.options = options
    self.found = found
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case title
    case notes
    case notesCut = "notes_cut"
    case priceMinor = "price_minor"
    case topPriceMinor = "top_price_minor"
    case currency
    case storeLinks = "store_links"
    case imageURLs = "image_urls"
    case options
    case found
  }

  public static let fields = WishboneAPI.fields(
    of: CodingKeys.self, lists: ["store_links": SearchStoreLink.fields, "options": SearchOption.fields])
}

/// The store link that a search read from a link.
public struct SearchStoreLink: Model, Equatable {
  /// The normalized address, after redirects.
  public let url: String

  /// The host of the address, with no `www.`.
  public let store: String
  public let priceMinor: Int?

  /// An ISO 4217 code. Nil exactly when there is no price.
  public let currency: String?

  /// The page's best image, or nil.
  public let imageURL: String?

  public init(url: String, store: String, priceMinor: Int? = nil, currency: String? = nil, imageURL: String? = nil) {
    self.url = url
    self.store = store
    self.priceMinor = priceMinor
    self.currency = currency
    self.imageURL = imageURL
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case url
    case store
    case priceMinor = "price_minor"
    case currency
    case imageURL = "image_url"
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self)
}

/// An option that a page lists, such as a size.
public struct SearchOption: Model, Equatable {
  /// Such as "Size".
  public let name: String

  /// What the page lists, at most 30. Empty when the page names the option and lists no values.
  public let values: [String]

  /// One of `values`: the one that the page or the address picks, or nil. Wishbone never guesses one.
  public let selected: String?

  public init(name: String, values: [String], selected: String? = nil) {
    self.name = name
    self.values = values
    self.selected = selected
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case name
    case values
    case selected
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self)
}

/// The body of `POST /lists/{id}/items`: the item that the add form holds.
public struct NewItem: Encodable, Sendable, Equatable {
  public var title: String
  public var notes: String?
  public var priceMinor: Int?
  public var topPriceMinor: Int?

  /// An ISO 4217 code. It goes only with a price.
  public var currency: String?
  public var storeLinks: [NewStoreLink]

  /// Uploaded images, in order. The first is the primary image.
  public var imageIDs: [String]

  public init(
    title: String, notes: String? = nil, priceMinor: Int? = nil, topPriceMinor: Int? = nil,
    currency: String? = nil, storeLinks: [NewStoreLink] = [], imageIDs: [String] = []
  ) {
    self.title = title
    self.notes = notes
    self.priceMinor = priceMinor
    self.topPriceMinor = topPriceMinor
    self.currency = currency
    self.storeLinks = storeLinks
    self.imageIDs = imageIDs
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case title
    case notes
    case priceMinor = "price_minor"
    case topPriceMinor = "top_price_minor"
    case currency
    case storeLinks = "store_links"
    case imageIDs = "image_ids"
    case primaryImageID = "primary_image_id"
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(title, forKey: .title)
    try container.encodeIfPresent(notes, forKey: .notes)
    try container.encodeIfPresent(priceMinor, forKey: .priceMinor)
    try container.encodeIfPresent(topPriceMinor, forKey: .topPriceMinor)
    if priceMinor != nil { try container.encodeIfPresent(currency, forKey: .currency) }
    if !storeLinks.isEmpty { try container.encode(storeLinks, forKey: .storeLinks) }
    if let primary = imageIDs.first {
      try container.encode(imageIDs, forKey: .imageIDs)
      try container.encode(primary, forKey: .primaryImageID)
    }
  }
}

/// A store link of a new item.
public struct NewStoreLink: Encodable, Sendable, Equatable {
  public var url: String
  public var priceMinor: Int?
  public var currency: String?

  /// The store's own address of its picture.
  public var imageURL: String?

  public init(url: String, priceMinor: Int? = nil, currency: String? = nil, imageURL: String? = nil) {
    self.url = url
    self.priceMinor = priceMinor
    self.currency = currency
    self.imageURL = imageURL
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case url
    case priceMinor = "price_minor"
    case currency
    case imageURL = "image_url"
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(url, forKey: .url)
    if let priceMinor {
      try container.encode(priceMinor, forKey: .priceMinor)
      try container.encodeIfPresent(currency, forKey: .currency)
    }
    try container.encodeIfPresent(imageURL, forKey: .imageURL)
  }
}

/// The body of `POST /images` for an image that the server downloads: a store's image from a search.
struct DownloadBody: Encodable, Sendable {
  let url: String

  enum CodingKeys: String, CodingKey, CaseIterable {
    case url
  }
}

/// One field of a `multipart/form-data` body.
struct FormField: Sendable, Equatable {
  let name: String
  let value: String
}

extension Endpoint where Response == SearchBody {
  /// Searches a link or typed words. The key makes a resend after a lost connection safe: the server gives the
  /// first answer again, and reads nothing again.
  static func search(_ text: String) -> Endpoint {
    Endpoint(route: .search, form: [FormField(name: "text", value: text)], idempotencyKey: UUID().uuidString)
  }
}

extension Endpoint where Response == Item {
  /// Adds an item to the list, with the key that the add form keeps. A second Add after a lost answer sends the
  /// same key, and the server adds the item once.
  static func createItem(_ item: NewItem, onList listID: String, key: String) -> Endpoint {
    Endpoint(route: .createItem, parameters: ["id": listID], body: item, idempotencyKey: key)
  }
}

extension Endpoint where Response == ImageSummary {
  /// Has the server download an image at the address, such as a store's image from a search.
  static func downloadImage(_ address: String) -> Endpoint {
    Endpoint(route: .uploadImage, body: DownloadBody(url: address))
  }
}
