import Foundation

// The values of the API that the local copy keeps as they are: each one is in a model, and in a row of the copy.
//
// **A change to how one of them is encoded is a change to the copy.** So `LocalDatabase.copySchema` rises with
// it, and a fitness test holds this file to that number.

/// The value of a field that the server hides from some callers.
///
/// The API leaves the key out for a caller who may not see the field, and sends `null` for a field with no value.
/// The two mean different things. For example, a `deactivated_at` of `null` says that the user is active, and a
/// missing one says nothing. See "Values" in the server's spec.
public enum Hideable<Value: Sendable>: Sendable {
  /// The key is absent: this caller may not see the field.
  case hidden

  /// This caller sees the field. Nil is a field with no value, which the API sends as `null`.
  case shown(Value?)

  /// The field's value. Nil when the field is hidden, and when it has no value.
  public var value: Value? {
    if case .shown(let value) = self { value } else { nil }
  }

  public var isHidden: Bool {
    if case .hidden = self { true } else { false }
  }

  /// The same field with its value changed: hidden stays hidden, and no value stays none.
  public func map<Other>(_ transform: (Value) -> Other) -> Hideable<Other> {
    switch self {
    case .hidden: .hidden
    case .shown(let value): .shown(value.map(transform))
    }
  }
}

extension Hideable: Equatable where Value: Equatable {}

/// How the copy keeps the value. This is not how the API sends it: a model reads one with
/// `KeyedDecodingContainer.hideable(_:forKey:)`.
extension Hideable: Codable where Value: Codable {
  private enum CodingKeys: String, CodingKey {
    case isHidden = "hidden"
    case value
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if try container.decodeIfPresent(Bool.self, forKey: .isHidden) == true {
      self = .hidden
    } else {
      self = .shown(try container.decodeIfPresent(Value.self, forKey: .value))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .hidden: try container.encode(true, forKey: .isHidden)
    case .shown(let value): try container.encodeIfPresent(value, forKey: .value)
    }
  }
}

extension KeyedDecodingContainer {
  /// A field of the API that can be hidden: `hidden` when the key is absent, and `shown(nil)` for `null`.
  func hideable<Value: Decodable>(_ type: Value.Type, forKey key: Key) throws -> Hideable<Value> {
    guard contains(key) else { return .hidden }
    return .shown(try decodeIfPresent(type, forKey: key))
  }

  /// A timestamp of the API: RFC 3339 in UTC, such as `2026-11-05T14:03:00Z`.
  func timestamp(forKey key: Key) throws -> Date {
    try Timestamp.date(try decode(String.self, forKey: key), at: codingPath + [key])
  }

  /// A timestamp that can be hidden.
  func hideableTimestamp(forKey key: Key) throws -> Hideable<Date> {
    switch try hideable(String.self, forKey: key) {
    case .hidden: .hidden
    case .shown(nil): .shown(nil)
    case .shown(let text?): .shown(try Timestamp.date(text, at: codingPath + [key]))
    }
  }
}

/// Reads the API's timestamps.
enum Timestamp {
  /// The moment that the text names. RFC 3339 allows a fraction of a second, so both forms are read.
  static func date(_ text: String, at path: [any CodingKey]) throws -> Date {
    if let date = try? Date(text, strategy: .iso8601) { return date }
    if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
    // The description names no value: the text is not family content, but nothing of an answer goes in a log.
    throw DecodingError.dataCorrupted(.init(codingPath: path, debugDescription: "This is not an RFC 3339 timestamp."))
  }
}

/// An image by its address and size, inside another resource.
public struct ImageSummary: Model, Codable, Equatable {
  public let id: String

  /// The address of the bytes, as a path at the instance address, such as `/api/v2/images/31`. A `GET` with the
  /// session's token returns them.
  public let url: String

  /// Pixels.
  public let width: Int
  public let height: Int

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case url
    case width
    case height
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self)
}

/// A date that can have no year, such as a birthday.
public struct PartialDate: Model, Codable, Equatable {
  /// 1 to 12.
  public let month: Int
  public let day: Int

  /// Nil when the year isn't known.
  public let year: Int?

  public init(month: Int, day: Int, year: Int? = nil) {
    self.month = month
    self.day = day
    self.year = year
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case month
    case day
    case year
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self)
}

/// What an occasion is. The enum is open: a kind that the app doesn't know is `unknown`.
public enum OccasionKind: Sendable, Hashable, Codable, RawRepresentable {
  /// Every user has one, made with the user.
  case birthday

  /// The admin's, for groups or for everyone. It has no user.
  case shared

  /// One user's, made by that user or their parent.
  case custom
  case unknown(String)

  /// The kind for the server's text, such as `birthday`.
  public init(rawValue: String) {
    switch rawValue {
    case "birthday": self = .birthday
    case "shared": self = .shared
    case "custom": self = .custom
    default: self = .unknown(rawValue)
    }
  }

  public var rawValue: String {
    switch self {
    case .birthday: "birthday"
    case .shared: "shared"
    case .custom: "custom"
    case .unknown(let text): text
    }
  }
}

/// The date rule of an occasion.
public struct OccasionRule: Model, Codable, Equatable {
  public let kind: Kind

  /// 1 to 12.
  public let month: Int

  /// For `annual` and `once`. Nil for the other kinds.
  public let day: Int?

  /// For `once` only.
  public let year: Int?

  /// For `nthWeekday` and `lastWeekday`. 0 is Sunday.
  public let weekday: Int?

  /// For `nthWeekday` only, 1 to 4.
  public let n: Int?

  public init(kind: Kind, month: Int, day: Int? = nil, year: Int? = nil, weekday: Int? = nil, n: Int? = nil) {
    self.kind = kind
    self.month = month
    self.day = day
    self.year = year
    self.weekday = weekday
    self.n = n
  }

  /// How the rule names its dates. The enum is open: a kind that the app doesn't know is `unknown`.
  public enum Kind: Sendable, Hashable, Codable, RawRepresentable {
    /// A date every year: `month` and `day`.
    case annual

    /// One date: `year`, `month` and `day`.
    case once

    /// The nth weekday of a month, every year: `n`, `weekday` and `month`.
    case nthWeekday

    /// The last weekday of a month, every year: `weekday` and `month`.
    case lastWeekday
    case unknown(String)

    /// The kind for the server's text, such as `nth_weekday`.
    public init(rawValue: String) {
      switch rawValue {
      case "annual": self = .annual
      case "once": self = .once
      case "nth_weekday": self = .nthWeekday
      case "last_weekday": self = .lastWeekday
      default: self = .unknown(rawValue)
      }
    }

    public var rawValue: String {
      switch self {
      case .annual: "annual"
      case .once: "once"
      case .nthWeekday: "nth_weekday"
      case .lastWeekday: "last_weekday"
      case .unknown(let text): text
      }
    }
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case kind
    case month
    case day
    case year
    case weekday
    case n
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self)
}

/// A list by its name, inside another resource.
public struct ListSummary: Model, Codable, Equatable {
  public let id: String
  public let name: String

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case name
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self)
}

/// An occasion by its kind and name, inside another resource.
public struct OccasionSummary: Model, Codable, Equatable {
  public let id: String
  public let kind: OccasionKind
  public let name: String

  public init(id: String, kind: OccasionKind, name: String) {
    self.id = id
    self.kind = kind
    self.name = name
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case kind
    case name
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self)
}

/// Where a gift is in its life. The enum is open: a state that the app doesn't know is `unknown`.
public enum GiftState: Sendable, Hashable, Codable, RawRepresentable {
  /// Claimed, and not given yet. Only its giver sees it.
  case open

  /// Given at its reveal. Its giver, its recipients, and their parents see it.
  case given
  case unknown(String)

  /// The state for the server's text, such as `open`.
  public init(rawValue: String) {
    switch rawValue {
    case "open": self = .open
    case "given": self = .given
    default: self = .unknown(rawValue)
    }
  }

  public var rawValue: String {
    switch self {
    case .open: "open"
    case .given: "given"
    case .unknown(let text): text
    }
  }
}

/// One line of a gift's `changed` flag: an item field that changed since the giver picked the gift, or since they
/// last answered the flag. See "Gift fields" in the server's route table.
///
/// The copy keeps it in the API's own shape, so it is read the same way from an answer and from the copy.
public struct GiftChange: Model, Codable, Equatable {
  public let field: Field

  /// The store link's address, for `storeLinkPrice` and `storeLinkRemoved`. Nil for the other fields.
  public let url: String?

  /// The value when the giver picked the gift, or last answered the flag. Hidden for a field that has no value in
  /// a line, such as `primaryImage`. `shown(nil)` is no value, such as no notes or no price.
  public let old: Hideable<Value>

  /// The value now, as `old` is.
  public let new: Hideable<Value>

  public init(field: Field, url: String? = nil, old: Hideable<Value> = .hidden, new: Hideable<Value> = .hidden) {
    self.field = field
    self.url = url
    self.old = old
    self.new = new
  }

  /// The item field that changed. The enum is open: a field that the app doesn't know is `unknown`.
  public enum Field: Sendable, Hashable, Codable, RawRepresentable {
    case title
    case notes
    case quantity
    case isUnlimited

    /// The item price: `price_minor`, `top_price_minor` and `currency` together.
    case price

    /// The primary image. The line says only that it changed.
    case primaryImage

    /// A store link's price. `url` names the store link.
    case storeLinkPrice

    /// A store link that was removed. `url` names it.
    case storeLinkRemoved
    case unknown(String)

    /// The field for the server's text, such as `is_unlimited`.
    public init(rawValue: String) {
      switch rawValue {
      case "title": self = .title
      case "notes": self = .notes
      case "quantity": self = .quantity
      case "is_unlimited": self = .isUnlimited
      case "price": self = .price
      case "primary_image": self = .primaryImage
      case "store_link_price": self = .storeLinkPrice
      case "store_link_removed": self = .storeLinkRemoved
      default: self = .unknown(rawValue)
      }
    }

    public var rawValue: String {
      switch self {
      case .title: "title"
      case .notes: "notes"
      case .quantity: "quantity"
      case .isUnlimited: "is_unlimited"
      case .price: "price"
      case .primaryImage: "primary_image"
      case .storeLinkPrice: "store_link_price"
      case .storeLinkRemoved: "store_link_removed"
      case .unknown(let text): text
      }
    }
  }

  /// A value of a line: a string, a number, a boolean, or a price.
  public enum Value: Sendable, Equatable, Codable {
    /// The title or the notes.
    case text(String)

    /// The quantity.
    case number(Int)

    /// The unlimited setting.
    case boolean(Bool)

    /// The item price, or a store link's.
    case price(Price)

    /// A value of a shape that the app doesn't know. The copy keeps that there was one, and not the value.
    case unknown

    public init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let value = try? container.decode(Bool.self) {
        self = .boolean(value)
      } else if let value = try? container.decode(Int.self) {
        self = .number(value)
      } else if let value = try? container.decode(String.self) {
        self = .text(value)
      } else if let value = try? container.decode(Price.self) {
        self = .price(value)
      } else {
        self = .unknown
      }
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case .text(let value): try container.encode(value)
      case .number(let value): try container.encode(value)
      case .boolean(let value): try container.encode(value)
      case .price(let value): try container.encode(value)
      // An object that is no price reads back as unknown.
      case .unknown: try container.encode([String: String]())
      }
    }
  }

  /// A price as one value: the price in the currency's minor unit, the top of a range, and an ISO 4217 code.
  public struct Price: Sendable, Equatable, Codable {
    public let priceMinor: Int
    public let topPriceMinor: Int?
    public let currency: String

    public init(priceMinor: Int, topPriceMinor: Int? = nil, currency: String) {
      self.priceMinor = priceMinor
      self.topPriceMinor = topPriceMinor
      self.currency = currency
    }

    enum CodingKeys: String, CodingKey {
      case priceMinor = "price_minor"
      case topPriceMinor = "top_price_minor"
      case currency
    }

    /// The API's own shape: no top of a range is `null`.
    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(priceMinor, forKey: .priceMinor)
      try container.encode(topPriceMinor, forKey: .topPriceMinor)
      try container.encode(currency, forKey: .currency)
    }
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case field
    case url
    case old
    case new
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    field = try container.decode(Field.self, forKey: .field)
    url = try container.decodeIfPresent(String.self, forKey: .url)
    old = try container.hideable(Value.self, forKey: .old)
    new = try container.hideable(Value.self, forKey: .new)
  }

  /// The API's own shape: a hidden value has no key, and no value is `null`.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(field, forKey: .field)
    try container.encodeIfPresent(url, forKey: .url)
    for (value, key) in [(old, CodingKeys.old), (new, .new)] {
      switch value {
      case .hidden: break
      case .shown(nil): try container.encodeNil(forKey: key)
      case .shown(let value?): try container.encode(value, forKey: key)
      }
    }
  }

  public static let fields = WishboneAPI.fields(of: CodingKeys.self)
}
