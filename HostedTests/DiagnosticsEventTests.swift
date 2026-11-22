import Foundation
import Testing
import WishboneAPI
@_spi(Testing) import WishboneDiagnostics
import WishboneUI

/// The app's own events, checked at the envelope that leaves the device: the one event type, the typed breadcrumbs,
/// the Wishbone version tag, and the scrubber. See "What may be sent" and "The app's own events" in `docs/spec.md`.
///
/// The tests are in the suite of `DiagnosticsTests`, which runs one test at a time: the SDK is one for the process.
extension DiagnosticsTests {
  /// Diagnostics that run, against a receiver, in a place of the test's own.
  private func running() async throws -> (EnvelopeReceiver, Place, Diagnostics) {
    let receiver = try await EnvelopeReceiver.start()
    let place = try Place()
    let diagnostics = place.diagnostics(
      Diagnostics.Build(dsn: receiver.dsn, environment: "test", isDebug: false, hasLaunchArgument: false))
    diagnostics.noticeShown()
    try #require(diagnostics.isRunning)
    return (receiver, place, diagnostics)
  }

  /// A client of the fake instance, with a session, which reports to the diagnostics.
  private func client(
    of instance: FakeInstance, _ diagnostics: Diagnostics, timeout: Duration = .seconds(30)
  ) throws -> APIClient {
    let address = try #require(InstanceAddress(instance.address))
    return APIClient(
      session: Session(instance: address, token: Self.token, userID: "7"),
      userAgent: UserAgent(version: "1.0", isPad: false), timeout: timeout, diagnostics: diagnostics.reporter)
  }

  /// A session's token, in the server's shape: 43 characters of base64url.
  private static let token = "Zk3q9XwL0pT7vB2nR8yH4mC6aJ1sD5fG0hK3lP9oQ2u"

  /// One fault of each kind.
  private static let faults: [Fault] = Fault.Kind.allCases.map { kind in
    switch kind {
    case .databaseWillNotOpen: .databaseWillNotOpen(ErrorCause(domain: .sqlite, code: 14))
    case .copyDropped: .copyDropped(from: 4, to: 5)
    case .undecodableAnswer: .undecodableAnswer(.listItems, keyPath: "data[].title")
    case .refusedWrite: .refusedWrite(.updateMe, code: "invalid_input")
    case .unknownErrorCode: .unknownErrorCode("brand_new_code")
    }
  }

  @Test("Each captured case gives one event with only its named fields")
  func eachCase() async throws {
    let (receiver, _, diagnostics) = try await running()
    for fault in Self.faults { diagnostics.reporter.capture(fault) }
    await diagnostics.flush()
    diagnostics.isOn = false

    let events = receiver.events
    #expect(events.count == Self.faults.count)
    for fault in Self.faults {
      let name = fault.kind.rawValue
      let matching = events.filter { tags($0)["fault"] == name }
      #expect(matching.count == 1, "\(name)")
      guard let event = matching.first else { continue }
      #expect((event["message"] as? [String: Any])?["formatted"] as? String == name)
      #expect(tags(event) == ["fault": name, "wishbone_version": "unknown"])
      let contexts = event["contexts"] as? [String: Any] ?? [:]
      #expect(Set(contexts.keys).isSubset(of: ["app", "device", "os", "fault"]), "\(contexts.keys)")
      let fields = contexts["fault"] as? [String: Any] ?? [:]
      #expect(Set(fields.keys) == fault.kind.fields, "\(name): \(fields.keys)")
      for (key, value) in fault.fields {
        switch value {
        case .word(let word): #expect(fields[key] as? String == word, "\(name).\(key)")
        case .number(let number): #expect(fields[key] as? Int == number, "\(name).\(key)")
        }
      }
      for field in ["extra", "exception", "request", "modules", "server_name", "logger", "transaction"] {
        #expect(event[field] == nil, "\(name) has \(field)")
      }
    }
  }

  @Test("A response that can't be decoded reports the path template and the key path, never a value")
  func undecodable() async throws {
    let (receiver, _, diagnostics) = try await running()
    let instance = try await FakeInstance.start { path in
      path == "/lists"
        ? FakeInstance.json(200, #"{"data":"Robin's secret wish","next_cursor":null}"#)
        : FakeInstance.problem(404, code: "not_found")
    }
    await #expect(throws: APIError.self) { try await client(of: instance, diagnostics).lists() }
    await diagnostics.flush()
    diagnostics.isOn = false

    let envelope = try #require(receiver.envelopes.first { !$0.events.isEmpty })
    let event = try #require(envelope.events.first)
    let fault = (event["contexts"] as? [String: Any])?["fault"] as? [String: String]
    #expect(fault == ["method": "GET", "path": "/lists", "key_path": "data"])
    #expect(!envelope.text.contains("Robin"))
    #expect(!envelope.text.contains("secret"))
  }

  @Test(
    "A request breadcrumb has the method, the template and the status class, and never the host, the query, a header or a body"
  )
  func requestBreadcrumb() async throws {
    let (receiver, _, diagnostics) = try await running()
    let instance = try await FakeInstance.start { _ in FakeInstance.json(200, #"{"data":[],"next_cursor":null}"#) }
    let port = String(try #require(URL(string: instance.address)?.port))
    _ = try await client(of: instance, diagnostics).userIDs(inGroup: "group-of-robin")
    // The request went with its host, its query, and its token. The breadcrumb names none of them.
    let request = try #require(instance.requests.first)
    #expect(request.target.contains("group_id=group-of-robin"))
    #expect(request.headers["authorization"] == "Bearer \(Self.token)")
    diagnostics.reporter.capture(.unknownErrorCode("brand_new_code"))
    await diagnostics.flush()
    diagnostics.isOn = false

    let envelope = try #require(receiver.envelopes.first { !$0.events.isEmpty })
    let event = try #require(envelope.events.first)
    let breadcrumbs = event["breadcrumbs"] as? [[String: Any]] ?? []
    #expect(breadcrumbs.count == 1)
    let breadcrumb = try #require(breadcrumbs.first)
    #expect(breadcrumb["category"] as? String == "request")
    #expect(breadcrumb["message"] == nil)
    #expect(breadcrumb["data"] as? [String: String] == ["method": "GET", "path": "/users", "status_class": "2xx"])
    for secret in ["127.0.0.1", ":\(port)", "group-of-robin", "group_id", "limit=", Self.token, "Bearer", "User-Agent"]
    {
      #expect(!envelope.strings.contains { $0.contains(secret) }, "The envelope holds \(secret).")
    }
  }

  @Test(
    "The scrubber strips a token, a login link, a host, and an address from every field of an event and a breadcrumb")
  func scrubber() async throws {
    let (receiver, _, diagnostics) = try await running()
    let secrets = [
      Self.token, "https://wishbone.smith-family.example:8443/login/\(Self.token)", "wishbone.smith-family.example",
      "192.168.1.20", "fe80::1ff:fe23:4567:890a", "robin@smith-family.example", "Bearer \(Self.token)",
      "/login/\(Self.token)", "localhost:8080",
    ]
    // The runtime's own free text, such as a `fatalError` message, goes in every field of free text too.
    let words = "Fatal error: Robin's bike"
    diagnostics.sendPlanted(secrets.joined(separator: " "), words: words)
    await diagnostics.flush()
    diagnostics.isOn = false

    let envelope = try #require(receiver.envelopes.first { !$0.events.isEmpty })
    let event = try #require(envelope.events.first)
    // The parts of the planted values that could name them. The envelope has random IDs (`event_id`, `trace_id`, a
    // `debug_id`, an image's address) and numbers (a time, the memory), which can hold a short run of hex or of
    // digits by chance: `890a` was once in a `trace_id`. So each part is in a shape that none of them can take: an
    // address's group or a port with its colon, which no ID and no time of day has (a time's fields are two digits),
    // and the check reads the envelope's strings, not its numbers. A leak still shows: the scrubber replaces a whole
    // address, or a host with its port, so a part of one that it left has its colon.
    let parts = [
      Self.token, "smith-family", "192.168.1.20", "fe80:", ":4567:", ":890a", "robin@", ":8443", ":8080", "localhost",
      "Robin", "Fatal error",
    ]
    for part in parts {
      #expect(part.contains { !"0123456789ABCDEFabcdefx-".contains($0) }, "A random ID can hold \(part).")
      #expect(!envelope.strings.contains { $0.contains(part) }, "The envelope holds \(part).")
    }
    // The check can fail: each part is found in an envelope with the planted values unscrubbed.
    let unscrubbed = try JSONSerialization.data(withJSONObject: ["message": ([words] + secrets).joined(separator: " ")])
    let planted = EnvelopeReceiver.envelope(Data(#"{}\#n{"type":"event"}\#n"#.utf8) + unscrubbed)
    for part in parts {
      #expect(planted.strings.contains { $0.contains(part) }, "The check can't find \(part).")
    }
    // The event still went: the scrubber strips what it carries, and drops only what is not the app's.
    #expect(user(event)["id"] != nil)
    #expect(tags(event) == ["wishbone_version": "unreadable"])
    #expect(event["message"] == nil)
    #expect(event["fingerprint"] == nil)
    #expect((event["breadcrumbs"] as? [Any] ?? []).isEmpty)
    // A frame keeps what came from the binary, with the text rules applied: the host and the address are gone.
    let exception = ((event["exception"] as? [String: Any])?["values"] as? [[String: Any]])?.first
    let frame = ((exception?["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]])?.first
    #expect((frame?["function"] as? String)?.contains("[host]") == true, "\(frame ?? [:])")
    #expect(exception?["value"] == nil)
    #expect(exception?["type"] == nil)
    // The planted image of the debug meta went, with its path through the text rules too, and its kind dropped.
    let images = (event["debug_meta"] as? [String: Any])?["images"] as? [[String: Any]] ?? []
    let image = images.first { ($0["debug_id"] as? String)?.uppercased() == Diagnostics.plantedImageID }
    #expect((image?["code_file"] as? String)?.contains("[url]") == true, "\(images)")
    #expect(image?["type"] == nil, "\(image ?? [:])")
  }

  @Test("Unreachable, a timeout, a cancel, the API's own 401, a 404, a 410, a version block and a 5xx give no event")
  func noEvent() async throws {
    let (receiver, _, diagnostics) = try await running()
    let instance = try await FakeInstance.start { path in
      switch path {
      case "/health": FakeInstance.json(200, #"{"version":"0.1.0"}"#)
      case "/users/u401": FakeInstance.problem(401, code: "unauthorized")
      case "/lists/l404": FakeInstance.problem(404, code: "not_found")
      case "/items/i410": FakeInstance.problem(410, code: "api_version_removed")
      case "/groups/g500": .answer(status: 500, contentType: "text/plain", body: Data("Robin".utf8))
      default: .hold
      }
    }
    let client = try client(of: instance, diagnostics)

    // A version block.
    #expect(try await client.checkVersion() == .tooOld(version: "0.1.0", minimum: minimumServerVersion))
    await #expect(throws: APIError.unauthorized) { try await client.user("u401") }
    await #expect(throws: APIError.self) { try await client.list("l404") }
    await #expect(throws: APIError.appTooOld) { try await client.item("i410") }
    await #expect(throws: APIError.unreachable(.noAnswer)) { try await client.group("g500") }
    // Unreachable: nothing listens on the port.
    let nowhere = APIClient(
      instance: try #require(InstanceAddress("http://127.0.0.1:9")), userAgent: UserAgent(version: "1.0", isPad: false),
      diagnostics: diagnostics.reporter)
    await #expect(throws: APIError.unreachable(.noAnswer)) { try await nowhere.health() }
    // A timeout: the instance holds the answer.
    let slow = try self.client(of: instance, diagnostics, timeout: .milliseconds(300))
    await #expect(throws: APIError.unreachable(.noAnswer)) { try await slow.occasion("held") }
    // A cancel, while the instance holds the answer.
    let held = Task { try await client.gift("held") }
    while !instance.requests.contains(where: { $0.path == "/api/v2/gifts/held" }) {
      try await Task.sleep(for: .milliseconds(20))
    }
    held.cancel()
    await #expect(throws: APIError.cancelled) { try await held.value }

    // The one event is the probe: the pipe works, and nothing before it was captured.
    diagnostics.sendProbe()
    await diagnostics.flush()
    diagnostics.isOn = false
    let events = receiver.events
    #expect(events.count == 1)
    #expect(events.allSatisfy { tags($0)["fault"] == nil })
  }

  @Test("Each sync leaves a breadcrumb at its start and one with its outcome, with no host and no address")
  func syncBreadcrumbs() async throws {
    let (receiver, _, diagnostics) = try await running()
    let instance = try await StandInInstance.start()
    // A sync through Sync now, and one in a background run, each to its end.
    let device = try signedInDevice(on: instance, diagnostics: diagnostics.reporter)
    #expect(try await #require(device.session).syncNow() == .succeeded)
    #expect(await device.refreshInBackground() == .succeeded)
    // A sync that can't reach its instance: nothing listens on the port.
    let nowhere = try signedInDevice(at: "http://127.0.0.1:9", diagnostics: diagnostics.reporter)
    #expect(try await #require(nowhere.session).syncNow() == .unreachable)
    diagnostics.sendProbe()
    await diagnostics.flush()
    diagnostics.isOn = false

    let envelope = try #require(receiver.envelopes.first { !$0.events.isEmpty })
    let event = try #require(envelope.events.first)
    let syncs = (event["breadcrumbs"] as? [[String: Any]] ?? []).filter {
      ["sync_started", "sync_ended"].contains($0["category"] as? String)
    }
    let crumbs = syncs.map { crumb in
      [crumb["category"] as? String ?? ""] + (crumb["data"] as? [String: String] ?? [:]).map { "\($0)=\($1)" }.sorted()
    }
    #expect(
      crumbs == [
        ["sync_started"], ["sync_ended", "outcome=succeeded"], ["sync_started"], ["sync_ended", "outcome=succeeded"],
        ["sync_started"], ["sync_ended", "outcome=unreachable"],
      ])
    #expect(syncs.allSatisfy { $0["message"] == nil })
    for secret in ["127.0.0.1", ":\(instance.port)", "a-token-for-the-test"] {
      #expect(!envelope.strings.contains { $0.contains(secret) }, "The envelope holds \(secret).")
    }
  }

  @Test("Every event has the Wishbone version tag")
  func versionTag() async throws {
    let (receiver, place, diagnostics) = try await running()
    let instance = try await FakeInstance.start { _ in FakeInstance.json(200, #"{"version":"v2.4.0+7773ada"}"#) }
    _ = try await client(of: instance, diagnostics).health()
    diagnostics.reporter.capture(.copyDropped(from: 4, to: 5))
    diagnostics.sendProbe()
    await diagnostics.flush()
    diagnostics.isOn = false

    // The next launch tags its events with the version, before it reads `GET /health` again.
    let relaunched = place.diagnostics(
      Diagnostics.Build(dsn: receiver.dsn, environment: "test", isDebug: false, hasLaunchArgument: false))
    relaunched.isOn = true
    relaunched.sendProbe()
    await relaunched.flush()
    // Signed out: the device has no instance.
    relaunched.reporter.wishboneVersion(nil)
    relaunched.sendProbe()
    await relaunched.flush()
    relaunched.isOn = false

    let events = receiver.events
    #expect(events.count == 4)
    #expect(events.map { tags($0)["wishbone_version"] } == ["2.4.0", "2.4.0", "2.4.0", "unknown"])
  }

  @Test("With diagnostics off, nothing is recorded")
  func offRecordsNothing() async throws {
    let receiver = try await EnvelopeReceiver.start()
    let place = try Place()
    let diagnostics = place.diagnostics(
      Diagnostics.Build(dsn: receiver.dsn, environment: "test", isDebug: false, hasLaunchArgument: false))

    // Before the notice, and with the switch off after it: the SDK doesn't run, and keeps nothing.
    for isOn in [true, false] {
      if !isOn {
        diagnostics.noticeShown()
        diagnostics.isOn = false
      }
      #expect(!diagnostics.isRunning)
      for fault in Self.faults { diagnostics.reporter.capture(fault) }
      diagnostics.reporter.leave(.request(.lists, .success))
      diagnostics.reporter.leave(.scenePhase(.active))
      diagnostics.reporter.leave(.placeOpened(.listPage))
      #expect(!FileManager.default.fileExists(atPath: place.folder.path(percentEncoded: false)))
    }
    #expect(receiver.envelopes.isEmpty)

    // On again: the one event is the probe, with no fault and no breadcrumb from before.
    diagnostics.isOn = true
    diagnostics.sendProbe()
    await diagnostics.flush()
    diagnostics.isOn = false
    let events = receiver.events
    #expect(events.count == 1)
    #expect(events.allSatisfy { tags($0)["fault"] == nil })
    #expect(events.allSatisfy { ($0["breadcrumbs"] as? [Any] ?? []).isEmpty })
  }

  @Test("A tap on the support row records nothing: no event, and no breadcrumb")
  func supportTapRecordsNothing() async throws {
    let (receiver, _, diagnostics) = try await running()
    let source = FakeStorefront(current: "USA")
    let support = SupportWishbone(source: source, address: SupportWishboneTests.page)
    let following = Task { await support.follow() }
    defer { following.cancel() }
    await until { support.shownPage != nil }

    // One breadcrumb before the tap, as a control, then the tap, then a fault so that an event carries the trail.
    diagnostics.reporter.leave(.scenePhase(.active))
    var opened: [URL] = []
    support.tap { opened.append($0) }
    #expect(opened == [SupportWishboneTests.page])
    diagnostics.reporter.capture(.unknownErrorCode("brand_new_code"))
    await diagnostics.flush()
    diagnostics.isOn = false

    let events = receiver.events
    #expect(events.count == 1)
    let event = try #require(events.first)
    #expect(tags(event)["fault"] == "unknown_error_code")
    let breadcrumbs = event["breadcrumbs"] as? [[String: Any]] ?? []
    #expect(breadcrumbs.map { $0["category"] as? String } == ["scene_phase"], "\(breadcrumbs)")
    // Nothing that leaves the device names the support page.
    #expect(receiver.envelopes.allSatisfy { !$0.text.lowercased().contains("coffee") })
    // The vocabulary has no case for it either.
    let names = Breadcrumb.Kind.allCases.map(\.rawValue) + Fault.Kind.allCases.map(\.rawValue)
    #expect(!names.contains { $0.contains("support") || $0.contains("coffee") || $0.contains("tip") })
  }

  /// The tags of an event.
  private func tags(_ event: [String: Any]) -> [String: String] {
    (event["tags"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
  }
}
