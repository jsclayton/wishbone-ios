// The diagnostics vocabulary: everything that the app may send of its own, as typed values. See "11. Diagnostics"
// in docs/spec.md, and "Diagnostics" in docs/architecture.md.
//
// It is here, and not in `WishboneDiagnostics`, because the modules that the extensions link name a fault where it
// happens. Only `WishboneDiagnostics` turns a value into what leaves the device, and only the app links it. An
// extension gives its device no reporter, so it sends nothing.

import Foundation

// MARK: - The one event type

/// The app's own fault: the one event type that the app captures. Each case has only the fields that it names, and
/// every field is a code, a number, a route, or a word from this file. There are no free-form strings: an error goes
/// as its domain and code, never as its message.
///
/// A new case needs a new ``Kind``, which says what the case sends, and the app's privacy manifest must declare it.
public enum Fault: Sendable, Equatable {
  /// The local database will not open: the error's domain and code.
  case databaseWillNotOpen(ErrorCause)

  /// A migration dropped the copy: the schema number that the database had, and the app's.
  case copyDropped(from: Int, to: Int)

  /// A sync can't read or write the copy, or its journal of unsent changes: the error's domain and code. Never a
  /// cancel.
  case copyFailed(ErrorCause)

  /// An answer that the client can't decode: the route, and the key path that failed. Never a value.
  case undecodableAnswer(Route, keyPath: String)

  /// A 400 or 422 refusal of a write that the app sent: the route, and the server's code. Never the body.
  case refusedWrite(Route, code: String)

  /// An error code that is not in ``ErrorCode``'s list: the code only.
  case unknownErrorCode(String)

  /// An undecodable answer at the key path, held to the fields that the route decodes. A key path that names no
  /// field of the route, such as one through a dictionary's keys, which are values, is sent as ``unlistedKeyPath``.
  public static func undecodable(_ route: Route, keyPath: String) -> Fault {
    let isListed =
      keyPath.isEmpty
      || route.decodedFields.contains {
        $0 == keyPath || $0.hasPrefix(keyPath + ".") || $0.hasPrefix(keyPath + "[]")
      }
    return .undecodableAnswer(route, keyPath: isListed ? keyPath : unlistedKeyPath)
  }

  /// A refusal of a write. The code is held to the shape of a code.
  public static func refused(_ route: Route, code: ErrorCode) -> Fault {
    .refusedWrite(route, code: Self.code(code))
  }

  /// An unknown code. The code is held to the shape of a code.
  public static func unknown(_ code: String) -> Fault {
    .unknownErrorCode(Self.code(.unknown(code)))
  }

  /// The key path of an undecodable answer that names no field of its route.
  public static let unlistedKeyPath = "(unlisted)"

  /// The code as the server writes it. A code that is not shaped like one, such as text that a proxy wrote, is sent
  /// as `(malformed)`: the server's codes are short words in snake case.
  static func code(_ code: ErrorCode) -> String {
    let text = code.text
    let isShaped =
      (1...64).contains(text.count)
      && text.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    return isShaped ? text : "(malformed)"
  }

  /// The kind of the fault.
  public var kind: Kind {
    switch self {
    case .databaseWillNotOpen: .databaseWillNotOpen
    case .copyDropped: .copyDropped
    case .copyFailed: .copyFailed
    case .undecodableAnswer: .undecodableAnswer
    case .refusedWrite: .refusedWrite
    case .unknownErrorCode: .unknownErrorCode
    }
  }

  /// The fault's fields, by their names in ``Kind/fields``. Each value is a code, a number, or a word of this file.
  public var fields: [String: FieldValue] {
    switch self {
    case .databaseWillNotOpen(let cause):
      ["domain": .word(cause.domain.rawValue), "code": .number(cause.code)]
    case .copyDropped(let from, let to):
      ["from": .number(from), "to": .number(to)]
    case .copyFailed(let cause):
      ["domain": .word(cause.domain.rawValue), "code": .number(cause.code)]
    case .undecodableAnswer(let route, let keyPath):
      ["method": .word(route.method), "path": .word(route.template), "key_path": .word(keyPath)]
    case .refusedWrite(let route, let code):
      ["method": .word(route.method), "path": .word(route.template), "code": .word(code)]
    case .unknownErrorCode(let code):
      ["code": .word(code)]
    }
  }

  /// A value of a field.
  public enum FieldValue: Sendable, Equatable {
    case word(String)
    case number(Int)
  }

  /// The kinds of fault, each with its name and its fields.
  public enum Kind: String, Sendable, CaseIterable {
    case databaseWillNotOpen = "database_will_not_open"
    case copyDropped = "copy_dropped"
    case copyFailed = "copy_failed"
    case undecodableAnswer = "undecodable_answer"
    case refusedWrite = "refused_write"
    case unknownErrorCode = "unknown_error_code"

    /// The names of the fields that a fault of the kind sends, and nothing more.
    public var fields: Set<String> {
      switch self {
      case .databaseWillNotOpen: ["domain", "code"]
      case .copyDropped: ["from", "to"]
      case .copyFailed: ["domain", "code"]
      case .undecodableAnswer: ["method", "path", "key_path"]
      case .refusedWrite: ["method", "path", "code"]
      case .unknownErrorCode: ["code"]
      }
    }
  }
}

/// The cause of a fault, as an error's domain and code. Never its message.
public struct ErrorCause: Sendable, Equatable {
  public let domain: Domain
  public let code: Int

  public init(domain: Domain, code: Int) {
    self.domain = domain
    self.code = code
  }

  /// The domain of an error, from a closed list. An error of any other domain is `other`, with its code.
  public enum Domain: String, Sendable, CaseIterable {
    /// SQLite's result code.
    case sqlite
    case cocoa
    case posix
    case other
  }

  /// The cause of any error, by the domain and code that it bridges to.
  public init(_ error: any Error) {
    let error = error as NSError
    let domains: [String: Domain] = [NSCocoaErrorDomain: .cocoa, NSPOSIXErrorDomain: .posix]
    self.init(domain: domains[error.domain] ?? .other, code: error.code)
  }
}

// MARK: - Breadcrumbs

/// A typed breadcrumb, made by the app only. A breadcrumb travels with the next event, and is never sent alone.
public enum Breadcrumb: Sendable, Equatable {
  /// A request: its method and path template, and its status class. Never the host, the query, a header, or a
  /// body.
  case request(Route, StatusClass)

  /// A change of a window scene's phase.
  case scenePhase(ScenePhase)

  /// A place that a window opened, named by its kind, never by what it shows.
  case placeOpened(PlaceKind)

  /// The start of a sync, whatever started it. It names nothing more: no address, and no count of anything.
  case syncStarted

  /// The outcome of a sync, whatever started it. It names only the outcome.
  case syncEnded(SyncEnd)

  /// The kind of the breadcrumb.
  public var kind: Kind {
    switch self {
    case .request: .request
    case .scenePhase: .scenePhase
    case .placeOpened: .placeOpened
    case .syncStarted: .syncStarted
    case .syncEnded: .syncEnded
    }
  }

  /// The breadcrumb's fields, by their names in ``Kind/fields``.
  public var fields: [String: String] {
    switch self {
    case .request(let route, let status):
      ["method": route.method, "path": route.template, "status_class": status.rawValue]
    case .scenePhase(let phase): ["phase": phase.rawValue]
    case .placeOpened(let kind): ["kind": kind.rawValue]
    case .syncStarted: [:]
    case .syncEnded(let end): ["outcome": end.rawValue]
    }
  }

  /// The kinds of breadcrumb, each with its category and its fields.
  public enum Kind: String, Sendable, CaseIterable {
    case request
    case scenePhase = "scene_phase"
    case placeOpened = "place_opened"
    case syncStarted = "sync_started"
    case syncEnded = "sync_ended"

    /// The names of the fields that a breadcrumb of the kind has, and nothing more.
    public var fields: Set<String> {
      switch self {
      case .request: ["method", "path", "status_class"]
      case .scenePhase: ["phase"]
      case .placeOpened: ["kind"]
      case .syncStarted: []
      case .syncEnded: ["outcome"]
      }
    }

    /// Every value that each field of the kind can have.
    public var values: [String: Set<String>] {
      switch self {
      case .request:
        [
          "method": Set(Route.allCases.map(\.method)), "path": Breadcrumb.pathTemplates,
          "status_class": Set(StatusClass.allCases.map(\.rawValue)),
        ]
      case .scenePhase: ["phase": Set(ScenePhase.allCases.map(\.rawValue))]
      case .placeOpened: ["kind": Set(PlaceKind.allCases.map(\.rawValue))]
      case .syncStarted: [:]
      case .syncEnded: ["outcome": Set(SyncEnd.allCases.map(\.rawValue))]
      }
    }
  }

  /// The allow list of path templates. A request is reported by one of these, or not at all. A fitness test holds
  /// every route that the client calls to this list.
  public static let pathTemplates: Set<String> = [
    "/health", "/login-links/redeem", "/versions", "/users/me", "/users", "/users/{id}", "/groups", "/groups/{id}",
    "/groups/{id}/users", "/groups/{id}/groups", "/occasions", "/occasions/{id}", "/occasions/{id}/groups", "/lists",
    "/lists/{id}", "/lists/{id}/recipients", "/lists/{id}/recipients/{user_id}", "/lists/{id}/items", "/items/{id}",
    "/items/{id}/gifts", "/invitations", "/invitations/{id}",
    "/gifts", "/gifts/{id}", "/blocked-stores", "/blocked-stores/{id}", "/users/me/sessions/current",
    "/users/me/confirm-profile", "/images", "/search",
  ]
}

/// The class of a request's status. `none` is a request that got no answer.
public enum StatusClass: String, Sendable, CaseIterable {
  case none
  case informational = "1xx"
  case success = "2xx"
  case redirect = "3xx"
  case clientError = "4xx"
  case serverError = "5xx"

  public init(status: Int?) {
    self =
      switch status {
      case .some(100..<200): .informational
      case .some(200..<300): .success
      case .some(300..<400): .redirect
      case .some(400..<500): .clientError
      case .some(500..<600): .serverError
      default: .none
      }
  }
}

/// The phase of a window scene.
public enum ScenePhase: String, Sendable, CaseIterable {
  case active
  case inactive
  case background
}

/// How a sync ended, as its breadcrumb names it. The session's `SyncOutcome` gives one of these.
public enum SyncEnd: String, Sendable, CaseIterable {
  /// The sync ran to its end.
  case succeeded

  /// The instance could not be reached.
  case unreachable

  /// The sync stopped: the instance refused, the copy can't be written, the session ended, or iOS ended a
  /// background run early.
  case stopped
}

/// The kind of a place that a window opens. A place is named by its kind, never by what it shows.
public enum PlaceKind: String, Sendable, CaseIterable {
  case home
  case lists
  case gifts
  case add
  case listPage = "list page"
  case userPage = "user page"
  case itemPage = "item page"
  case people
  case settings
}

// MARK: - Each error's side

/// What diagnostics do with an error. Every error type of the app picks its side, where the type is defined: see
/// ``Diagnosed``.
public enum DiagnosticSide: Sendable, Equatable {
  /// The app's own fault, sent as an event.
  case captured(Fault)

  /// A breadcrumb, which travels with the next event.
  case breadcrumb(Breadcrumb)

  /// Nothing: the error is no fault of the app.
  case never
}

/// An error of the app. Every error type of the app is one, so that it names its side: a fitness test holds every
/// error type of the app's code to this protocol. See "The app's own events" in `docs/spec.md`.
public protocol Diagnosed: Error {
  /// What diagnostics do with the error.
  var diagnosticSide: DiagnosticSide { get }
}

// MARK: - The reporter

/// Where the app's own faults, its breadcrumbs, and the instance's version go. The app gives its device the
/// reporter of `WishboneDiagnostics`. An extension gives none, and sends nothing.
///
/// Each call is safe from any thread, and returns at once. With diagnostics off, nothing is recorded.
public protocol DiagnosticsReporter: Sendable {
  /// Captures the app's own fault.
  func capture(_ fault: Fault)

  /// Leaves a breadcrumb for the next event.
  func leave(_ breadcrumb: Breadcrumb)

  /// The instance's Wishbone version, from `GET /health`, which tags every event. Nil when the device has no
  /// instance.
  func wishboneVersion(_ version: ServerVersion?)
}

extension DiagnosticsReporter {
  /// What an error's side asks for.
  public func report(_ error: some Diagnosed) {
    switch error.diagnosticSide {
    case .captured(let fault): capture(fault)
    case .breadcrumb(let breadcrumb): leave(breadcrumb)
    case .never: break
    }
  }
}

/// No diagnostics: the reporter of the extensions, and of the tests that don't check diagnostics.
public struct NoDiagnostics: DiagnosticsReporter {
  public init() {}
  public func capture(_ fault: Fault) {}
  public func leave(_ breadcrumb: Breadcrumb) {}
  public func wishboneVersion(_ version: ServerVersion?) {}
}

extension DiagnosticsReporter where Self == NoDiagnostics {
  /// No diagnostics.
  public static var none: NoDiagnostics { NoDiagnostics() }
}

// MARK: - What the vocabulary sends

/// Everything that diagnostics can send, each with the data type of Apple's privacy manifest that it is. A fitness
/// test holds the app's privacy manifest to exactly the data types here.
public enum DiagnosticsReport: Sendable, Equatable {
  /// A crash, which the SDK finds.
  case crash

  /// An app hang in the foreground, which the SDK finds.
  case appHang

  /// An out-of-memory or watchdog termination, which the SDK finds.
  case termination

  /// The app's own fault.
  case fault(Fault.Kind)

  /// A breadcrumb, with the next event.
  case breadcrumb(Breadcrumb.Kind)

  /// What each event carries: the app's version and build, the device's model and memory, and the iOS version.
  case versionsAndDevice

  /// The tag on every event: the instance's Wishbone version.
  case wishboneVersion

  /// The diagnostics ID: the app's own random ID for the device, which turning diagnostics off deletes.
  case diagnosticsID

  /// Everything that diagnostics can send.
  public static var allCases: [DiagnosticsReport] {
    [.crash, .appHang, .termination, .versionsAndDevice, .wishboneVersion, .diagnosticsID]
      + Fault.Kind.allCases.map(DiagnosticsReport.fault) + Breadcrumb.Kind.allCases.map(DiagnosticsReport.breadcrumb)
  }

  /// The data type of Apple's privacy manifest that the report is.
  public var dataType: PrivacyDataType {
    switch self {
    case .crash: .crashData
    case .appHang, .termination: .performanceData
    case .fault, .breadcrumb, .versionsAndDevice, .wishboneVersion, .diagnosticsID: .otherDiagnosticData
    }
  }

  /// A data type of Apple's privacy manifest, by its key.
  public enum PrivacyDataType: String, Sendable, CaseIterable {
    case crashData = "NSPrivacyCollectedDataTypeCrashData"
    case performanceData = "NSPrivacyCollectedDataTypePerformanceData"
    case otherDiagnosticData = "NSPrivacyCollectedDataTypeOtherDiagnosticData"
  }
}
