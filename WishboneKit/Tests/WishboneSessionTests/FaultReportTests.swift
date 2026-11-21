import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// Each place where the app's own fault happens reports it to diagnostics, by code only, and each request leaves a
/// breadcrumb. What then leaves the device is checked at the envelope, in the hosted tests. See "The app's own
/// events" in `docs/spec.md`.
@Suite("What the app reports to diagnostics", .timeLimit(.minutes(1)))
@MainActor
struct FaultReportTests {
  typealias Route = NetworkConditioner.Route

  let instance: Instance
  let diagnostics = RecordingDiagnostics()

  init() async throws {
    instance = try await Instance()
  }

  /// A device that the keychain and the marker already hold the session for, as at a relaunch.
  private func relaunched(as session: Session, storage: SessionStorage) -> Device {
    instance.keychain.save(session)
    instance.marker.place()
    return instance.device(storage: storage, diagnostics: diagnostics)
  }

  private var session: Session {
    get throws {
      Session(instance: try instance.address, token: "a-token-for-the-test", userID: "7")
    }
  }

  @Test("A database whose folder can't be made is captured by its domain and code, and the session still works")
  func databaseWillNotOpen() throws {
    let folder = try ScratchDirectory("device")
    try Data().write(to: folder.url.appending(path: "Sessions"))

    let device = relaunched(as: try session, storage: .folder(folder.url))
    #expect(device.session != nil)
    let faults = diagnostics.faults
    #expect(faults.count == 1, "\(faults)")
    guard case .databaseWillNotOpen(let cause) = faults.first else {
      Issue.record("\(faults)")
      return
    }
    #expect(cause.domain == .cocoa)
  }

  @Test("A damaged database file is captured as SQLite's code, once, and is made again")
  func damagedDatabase() throws {
    let session = try session
    let folder = try ScratchDirectory("device")
    let own = folder.url.appending(path: "Sessions").appending(path: session.opaqueName)
    try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
    try Data("not a database".utf8).write(to: own.appending(path: "database.sqlite"))

    let device = relaunched(as: session, storage: .folder(folder.url))
    #expect(device.session != nil)
    // SQLITE_NOTADB.
    #expect(diagnostics.faults == [.databaseWillNotOpen(ErrorCause(domain: .sqlite, code: 26))])
  }

  @Test("A copy that the schema number drops is captured as the two numbers. A new database drops nothing")
  func copyDropped() throws {
    let session = try session
    let folder = try ScratchDirectory("device")
    do {
      // The device goes at the end of this scope, as the app does when it ends.
      let first = relaunched(as: session, storage: .folder(folder.url))
      #expect(first.session != nil)
    }
    #expect(diagnostics.faults.isEmpty)
    try DatabaseFile(under: folder.url).execute("PRAGMA user_version = 3")

    let device = relaunched(as: session, storage: .folder(folder.url))
    #expect(device.session != nil)
    #expect(diagnostics.faults == [.copyDropped(from: 3, to: 5)])
  }

  @Test("An answer that can't be decoded is captured as its route and key path, never a value")
  func undecodableAnswer() async throws {
    let robin = try await instance.person()
    instance.conditioner.answer(
      Route("GET", "/versions"), with: try .json(200, ["data": .string("Robin's secret wish"), "next_cursor": .null]))
    let device = instance.device(diagnostics: diagnostics)
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    #expect(device.session != nil)

    #expect(diagnostics.faults == [.undecodableAnswer(.versions, keyPath: "data")])
    #expect(!"\(diagnostics.faults)".contains("secret"))
  }

  @Test("A key path that names no field of the route is sent as unlisted, so a dictionary's key never goes")
  func unlistedKeyPath() {
    #expect(
      Fault.undecodable(.versions, keyPath: "data[].kind") == .undecodableAnswer(.versions, keyPath: "data[].kind"))
    #expect(
      Fault.undecodable(.versions, keyPath: "data[].Robin's list")
        == .undecodableAnswer(.versions, keyPath: Fault.unlistedKeyPath))
    #expect(Fault.undecodable(.health, keyPath: "") == .undecodableAnswer(.health, keyPath: ""))
  }

  @Test("A 422 refusal of a write is captured as its route and code, never the body")
  func refusedWrite() async throws {
    let robin = try await instance.person()
    instance.conditioner.answer(
      Route("PATCH", "/users/me"),
      with: try .problem(422, code: "invalid_input", detail: "Robin's zone is not a zone"))
    let device = instance.device(timeZone: .fixed("Europe/Paris"), diagnostics: diagnostics)
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    #expect(device.session != nil)

    #expect(diagnostics.faults == [.refusedWrite(.updateMe, code: "invalid_input")])
  }

  @Test("A code that is not in the app's list is captured, by the code only")
  func unknownErrorCode() async throws {
    let robin = try await instance.person()
    instance.conditioner.answer(
      Route("GET", "/versions"), with: try .problem(403, code: "brand_new_code", detail: "Robin can't see this"))
    let device = instance.device(diagnostics: diagnostics)
    await device.signIn(pasting: try await instance.loginLink(for: robin))

    #expect(diagnostics.faults == [.unknownErrorCode("brand_new_code")])
    // A code that is not shaped like one goes as malformed.
    #expect(Fault.unknown("Robin's code") == .unknownErrorCode("(malformed)"))
  }

  @Test("A 404, a 5xx, an unreachable instance, and the API's own 401 capture nothing")
  func noFault() async throws {
    let robin = try await instance.person()
    let device = instance.device(diagnostics: diagnostics)
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    let session = try #require(device.session)

    instance.conditioner.answer(Route("GET", "/versions"), with: try .problem(404, code: "not_found"))
    await session.syncNow()
    instance.conditioner.passEverything()
    instance.conditioner.answer(Route("GET", "/versions"), with: .init(status: 503))
    await session.syncNow()
    instance.conditioner.passEverything()
    instance.conditioner.dropEverything()
    await session.syncNow()
    instance.conditioner.passEverything()
    instance.conditioner.answer(Route("GET", "/versions"), with: try .problem(401, code: "unauthorized"))
    await session.syncNow()
    await until { device.session == nil }

    #expect(diagnostics.faults.isEmpty, "\(diagnostics.faults)")
  }

  @Test("Each request leaves a breadcrumb of its route and status class. The version tags events until sign-out")
  func breadcrumbsAndVersion() async throws {
    let robin = try await instance.person()
    let device = instance.device(diagnostics: diagnostics)
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    let session = try #require(device.session)

    let requests = diagnostics.breadcrumbs.compactMap { breadcrumb -> String? in
      guard case .request(let route, let status) = breadcrumb else { return nil }
      return "\(route.method) \(route.template) \(status.rawValue)"
    }
    #expect(
      Array(requests.prefix(4)) == [
        "GET /health 2xx", "POST /login-links/redeem 2xx", "GET /users/me 2xx", "GET /versions 2xx",
      ])
    #expect(diagnostics.version != nil)

    instance.conditioner.dropEverything()
    await session.syncNow()
    #expect(diagnostics.breadcrumbs.last == .request(.versions, .none))

    instance.conditioner.passEverything()
    await device.signOut()
    #expect(diagnostics.breadcrumbs.last == .request(.revokeCurrentSession, .success))
    #expect(diagnostics.version == nil)
  }

  @Test("A sign-in that doesn't end signed in leaves no version to tag events with")
  func noVersionWithoutSignIn() async throws {
    let robin = try await instance.person()
    instance.conditioner.answer(Route("GET", "/health"), with: try .json(200, ["version": .string("0.1.0")]))
    let device = instance.device(diagnostics: diagnostics)
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    #expect(device.session == nil)
    // The version check read the version, and the device has no instance after it.
    #expect(diagnostics.breadcrumbs.first == .request(.health, .success))
    #expect(diagnostics.version == nil)
  }
}
