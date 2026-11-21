import Foundation

/// Any JSON value. The fixture builder and the tests read the server's answers through it, so they don't depend on
/// the app's models, which are what the tests check.
public enum JSON: Sendable, Equatable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSON])
  case object([String: JSON])

  public init(parsing data: Data) throws {
    self = try JSONDecoder().decode(JSON.self, from: data)
  }

  /// The value as JSON text.
  public var data: Data {
    get throws {
      try JSONEncoder().encode(self)
    }
  }

  /// The member of an object. `.null` when the value is not an object, or has no such member.
  public subscript(key: String) -> JSON {
    if case .object(let members) = self { members[key] ?? .null } else { .null }
  }

  /// The element of an array. `.null` when the value is not an array, or is too short.
  public subscript(index: Int) -> JSON {
    if case .array(let elements) = self, elements.indices.contains(index) { elements[index] } else { .null }
  }

  public var string: String? {
    if case .string(let value) = self { value } else { nil }
  }

  public var bool: Bool? {
    if case .bool(let value) = self { value } else { nil }
  }

  public var number: Double? {
    if case .number(let value) = self { value } else { nil }
  }

  public var array: [JSON]? {
    if case .array(let value) = self { value } else { nil }
  }

  public var isNull: Bool {
    self == .null
  }
}

extension JSON: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSON].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSON].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

extension JSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
  public init(nilLiteral: ()) {
    self = .null
  }

  public init(booleanLiteral value: Bool) {
    self = .bool(value)
  }

  public init(integerLiteral value: Int) {
    self = .number(Double(value))
  }

  public init(floatLiteral value: Double) {
    self = .number(value)
  }

  public init(stringLiteral value: String) {
    self = .string(value)
  }

  public init(arrayLiteral elements: JSON...) {
    self = .array(elements)
  }

  public init(dictionaryLiteral elements: (String, JSON)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
}
