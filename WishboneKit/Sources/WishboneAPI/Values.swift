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
