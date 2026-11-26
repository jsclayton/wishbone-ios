import Foundation

/// The body of `PATCH /items/{id}`: a merge patch of only the fields that change, so a field that is absent doesn't
/// change, and `null` clears a field that can be cleared. Edit item sends it, as an unsent change, with no
/// `If-Match`. See "No If-Match" in `docs/spec.md`, and `PATCH /items/{id}` in the server's route table.
///
/// It is `Codable` because the journal keeps it as the change's patch: it decodes `null` apart from a field that is
/// absent, so the patch that the journal reads back is the one that it saved.
public struct ItemChanges: Codable, Sendable, Equatable {
  /// The title, 1 to 300 characters. It can't be cleared.
  public var title: String?

  /// The notes, at most 2000 characters. An empty string clears them.
  public var notes: String?

  /// The price, in the currency's minor unit. `.some(nil)` clears it, and the top price and the currency with it.
  public var priceMinor: Int??

  /// The top of a price range, for "Up to". `.some(nil)` makes the price a single amount again.
  public var topPriceMinor: Int??

  /// The price's ISO 4217 code. It goes only with a price.
  public var currency: String?

  /// How many are wanted, at least 1.
  public var quantity: Int?

  /// Whether the item is always wanted.
  public var isUnlimited: Bool?

  /// Every image of the item, in order: the whole array, which replaces the item's. An image left out is removed,
  /// and the server deletes it. At most 5, else 422 `too_many_images`.
  public var imageIDs: [String]?

  /// The primary image: one of the item's images after the change. Absent keeps it, and when it is removed, the
  /// first image that is left takes its place.
  public var primaryImageID: String?

  public init(
    title: String? = nil, notes: String? = nil, priceMinor: Int?? = nil, topPriceMinor: Int?? = nil,
    currency: String? = nil, quantity: Int? = nil, isUnlimited: Bool? = nil, imageIDs: [String]? = nil,
    primaryImageID: String? = nil
  ) {
    self.title = title
    self.notes = notes
    self.priceMinor = priceMinor
    self.topPriceMinor = topPriceMinor
    self.currency = currency
    self.quantity = quantity
    self.isUnlimited = isUnlimited
    self.imageIDs = imageIDs
    self.primaryImageID = primaryImageID
  }

  /// Whether the patch changes nothing.
  public var isEmpty: Bool {
    self == ItemChanges()
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case title
    case notes
    case priceMinor = "price_minor"
    case topPriceMinor = "top_price_minor"
    case currency
    case quantity
    case isUnlimited = "is_unlimited"
    case imageIDs = "image_ids"
    case primaryImageID = "primary_image_id"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    title = try container.decodeIfPresent(String.self, forKey: .title)
    notes = try container.decodeIfPresent(String.self, forKey: .notes)
    priceMinor = try Self.decodeClearable(Int.self, forKey: .priceMinor, in: container)
    topPriceMinor = try Self.decodeClearable(Int.self, forKey: .topPriceMinor, in: container)
    currency = try container.decodeIfPresent(String.self, forKey: .currency)
    quantity = try container.decodeIfPresent(Int.self, forKey: .quantity)
    isUnlimited = try container.decodeIfPresent(Bool.self, forKey: .isUnlimited)
    imageIDs = try container.decodeIfPresent([String].self, forKey: .imageIDs)
    primaryImageID = try container.decodeIfPresent(String.self, forKey: .primaryImageID)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(title, forKey: .title)
    try container.encodeIfPresent(notes, forKey: .notes)
    try Self.encodeClearable(priceMinor, forKey: .priceMinor, in: &container)
    try Self.encodeClearable(topPriceMinor, forKey: .topPriceMinor, in: &container)
    try container.encodeIfPresent(currency, forKey: .currency)
    try container.encodeIfPresent(quantity, forKey: .quantity)
    try container.encodeIfPresent(isUnlimited, forKey: .isUnlimited)
    try container.encodeIfPresent(imageIDs, forKey: .imageIDs)
    try container.encodeIfPresent(primaryImageID, forKey: .primaryImageID)
  }

  /// A field that can be cleared: absent is nil, `null` is `.some(nil)`.
  private static func decodeClearable<Value: Decodable>(
    _ type: Value.Type, forKey key: CodingKeys, in container: KeyedDecodingContainer<CodingKeys>
  ) throws -> Value?? {
    guard container.contains(key) else { return nil }
    if try container.decodeNil(forKey: key) { return .some(nil) }
    return .some(try container.decode(Value.self, forKey: key))
  }

  /// A field that can be cleared: nil is absent, `.some(nil)` is `null`.
  private static func encodeClearable<Value: Encodable>(
    _ value: Value??, forKey key: CodingKeys, in container: inout KeyedEncodingContainer<CodingKeys>
  ) throws {
    switch value {
    case .none: break
    case .some(.none): try container.encodeNil(forKey: key)
    case .some(.some(let value)): try container.encode(value, forKey: key)
    }
  }
}
