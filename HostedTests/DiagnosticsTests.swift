import Foundation
import Testing
import WishboneAPI
@_spi(Testing) import WishboneDiagnostics
import WishboneSession

/// Diagnostics on this device: when the SDK starts, the switch, and what the SDK sends, checked at the envelope that
/// leaves the device. See "11. Diagnostics" in `docs/spec.md`.
///
/// The SDK is one for the whole process, so the tests run one at a time. Each test has its own defaults and its own
/// folder, and turns diagnostics off at its end, which stops the SDK.
@Suite("Diagnostics", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct DiagnosticsTests {
  @Test("With an empty DSN, diagnostics never start")
  func emptyDSN() throws {
    let place = try Place()
    for dsn in ["", "  "] {
      let diagnostics = place.diagnostics(
        Diagnostics.Build(
          dsn: dsn, environment: "test", isDebug: false, hasLaunchArgument: false))
      diagnostics.start()
      diagnostics.noticeShown()
      diagnostics.isOn = false
      diagnostics.isOn = true
      diagnostics.start()
      #expect(!diagnostics.isRunning)
      #expect(!Diagnostics.isSDKEnabled)
      #expect(!FileManager.default.fileExists(atPath: place.folder.path(percentEncoded: false)))
      // The switch still shows, and still works on the device.
      #expect(diagnostics.isOn)
      #expect(diagnostics.diagnosticsID != nil)
      diagnostics.isOn = false
    }
  }

  @Test("Diagnostics don't start before the signed-out screen has shown the notice, and start at every launch after")
  func notice() async throws {
    let receiver = try await EnvelopeReceiver.start()
    let place = try Place()
    let build = Diagnostics.Build(dsn: receiver.dsn, environment: "test", isDebug: false, hasLaunchArgument: false)

    // A fresh install: on by default, but the notice hasn't shown.
    let first = place.diagnostics(build)
    #expect(first.isOn)
    #expect(!first.hasShownNotice)
    first.start()
    #expect(!first.isRunning)
    #expect(!Diagnostics.isSDKEnabled)

    // A later launch that has still not shown the notice.
    let second = place.diagnostics(build)
    second.start()
    #expect(!second.isRunning)

    // The notice shows, and the SDK starts.
    second.noticeShown()
    #expect(second.isRunning)
    #expect(Diagnostics.isSDKEnabled)
    second.isOn = false
    #expect(!Diagnostics.isSDKEnabled)

    // The next launch remembers the notice: once the switch is on, the SDK starts with no notice again.
    let third = place.diagnostics(build)
    #expect(third.hasShownNotice)
    third.isOn = true
    #expect(third.isRunning)
    #expect(Diagnostics.isSDKEnabled)
    third.isOn = false
  }

  @Test("Off deletes the ID and anything not sent, and nothing more leaves. On again makes a new ID")
  func off() async throws {
    let receiver = try await EnvelopeReceiver.start()
    let place = try Place()
    let diagnostics = place.diagnostics(
      Diagnostics.Build(
        dsn: receiver.dsn, environment: "test", isDebug: false, hasLaunchArgument: false))
    diagnostics.noticeShown()
    let firstID = try #require(diagnostics.diagnosticsID)

    // While on, a report leaves with the device's ID.
    diagnostics.sendProbe()
    await diagnostics.flush()
    #expect(receiver.events.map(user) == [["id": firstID]])

    // A report that can't be sent yet stays in the folder.
    receiver.set(.drop)
    diagnostics.sendProbe()
    await diagnostics.flush()
    #expect(try place.unsentEnvelopes() > 0)

    // Off: the ID and what is not sent are gone, and the SDK stops.
    diagnostics.isOn = false
    #expect(diagnostics.diagnosticsID == nil)
    #expect(!diagnostics.isRunning)
    #expect(!Diagnostics.isSDKEnabled)
    #expect(!FileManager.default.fileExists(atPath: place.folder.path(percentEncoded: false)))
    diagnostics.sendProbe()

    // On again: a new ID. The SDK sends what it holds when it starts, so the one new report shows that the report
    // that was not sent is gone, and that the choice itself sent nothing.
    receiver.set(.answer)
    let before = receiver.envelopes.count
    diagnostics.isOn = true
    let secondID = try #require(diagnostics.diagnosticsID)
    #expect(secondID != firstID)
    #expect(diagnostics.isRunning)
    diagnostics.sendProbe()
    await diagnostics.flush()
    let after = receiver.envelopes.dropFirst(before)
    #expect(after.count == 1)
    #expect(after.flatMap(\.events).map(user) == [["id": secondID]])
    diagnostics.isOn = false
  }

  @Test("The choice is the device's: it survives a sign-out, and a sign-in as another user")
  func choiceSurvivesSignOut() async throws {
    let accessGroup = try #require(Bundle.main.object(forInfoDictionaryKey: "WishboneKeychainAccessGroup") as? String)
    let keychain = SystemSessionKeychain(accessGroup: accessGroup)
    let storage = URL.cachesDirectory.appending(
      path: "DiagnosticsTest-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: storage) }
    // The sessions are this install's: the marker is placed.
    let marker = FileInstallMarker(container: storage)
    try marker.place()
    let setup = Device.Setup(
      userAgent: UserAgent(version: "1.0", isPad: false), keychain: keychain, marker: marker,
      storage: .folder(storage))
    // The bundle has no test server, so the instance can't be reached. The device is cleared all the same.
    let instance = try #require(InstanceAddress("http://127.0.0.1:9"))

    // The app's own diagnostics, in the app's own defaults. A Debug build with no launch argument never starts them.
    let app = Diagnostics.app()
    defer { Diagnostics.app().isOn = true }
    #expect(!app.isRunning)

    for isOn in [false, true] {
      app.isOn = isOn
      let id = app.diagnosticsID

      // Signed in as one user, then signed out.
      try keychain.save(Session(instance: instance, token: "a-token-for-the-test", userID: "7"))
      let device = Device(setup)
      #expect(device.session != nil)
      await device.signOut()
      #expect(device.session == nil)
      #expect(Diagnostics.app().isOn == isOn)
      #expect(Diagnostics.app().diagnosticsID == id)

      // Signed in as another user.
      try keychain.save(Session(instance: instance, token: "another-token", userID: "8"))
      let other = Device(setup)
      #expect(other.session?.session.userID == "8")
      #expect(Diagnostics.app().isOn == isOn)
      #expect(Diagnostics.app().diagnosticsID == id)
      try keychain.delete()
    }

    // The choice is not in the shared container, where an extension could read it.
    let appGroup = try #require(Bundle.main.object(forInfoDictionaryKey: "WishboneAppGroup") as? String)
    let shared = try #require(UserDefaults(suiteName: appGroup))
    #expect(!shared.dictionaryRepresentation().keys.contains { $0.hasPrefix("WishboneDiagnostics") })
  }

  @Test("Every feature of the SDK that the spec lists as off is off in the options")
  func features() {
    var expected = Dictionary(uniqueKeysWithValues: Diagnostics.sdkFeatures().keys.map { ($0, false) })
    // On: crashes, with the terminations that the SDK finds, and app hangs.
    for feature in ["crashes", "watchdog terminations", "app hangs"] { expected[feature] = true }
    #expect(Diagnostics.sdkFeatures() == expected)
    // Each feature that the spec names as off is in the list.
    let named = [
      "user and IP address", "tracing", "profiling", "metrics", "logs", "session replay", "screenshots",
      "view hierarchy", "automatic breadcrumbs", "network breadcrumbs",
    ]
    #expect(Set(named).isSubset(of: expected.keys))
  }

  @Test("A Debug build doesn't start diagnostics without the launch argument")
  func debugBuild() async throws {
    let receiver = try await EnvelopeReceiver.start()
    let place = try Place()

    let plain = place.diagnostics(
      Diagnostics.Build(
        dsn: receiver.dsn, environment: "test", isDebug: true, hasLaunchArgument: false))
    plain.noticeShown()
    #expect(!plain.isRunning)
    #expect(!Diagnostics.isSDKEnabled)

    let launched = place.diagnostics(
      Diagnostics.Build(
        dsn: receiver.dsn, environment: "test", isDebug: true, hasLaunchArgument: true))
    launched.start()
    #expect(launched.isRunning)
    #expect(Diagnostics.isSDKEnabled)
    launched.isOn = false

    // The tests are a Debug build, launched with no such argument.
    let current = Diagnostics.Build.current
    #expect(current.isDebug)
    #expect(!current.hasLaunchArgument)
  }

  @Test("An event carries the diagnostics ID as its only ID and its only user field, and no time zone or locale")
  func envelope() async throws {
    let receiver = try await EnvelopeReceiver.start()
    let place = try Place()
    let diagnostics = place.diagnostics(
      Diagnostics.Build(
        dsn: receiver.dsn, environment: "testflight", isDebug: false, hasLaunchArgument: false))
    diagnostics.noticeShown()
    let id = try #require(diagnostics.diagnosticsID)
    diagnostics.sendProbe()
    await diagnostics.flush()
    diagnostics.isOn = false

    let envelope = try #require(receiver.envelopes.first { !$0.events.isEmpty })
    let event = try #require(envelope.events.first)
    #expect(user(event) == ["id": id])
    #expect(event["environment"] as? String == "testflight")
    let contexts = try #require(event["contexts"] as? [String: Any])
    // The time zone goes only to the family's server.
    #expect(contexts["culture"] == nil)
    let device = try #require(contexts["device"] as? [String: Any])
    #expect(device["model"] != nil)
    #expect(device["timezone"] == nil)
    #expect(device["locale"] == nil)
    // The diagnostics ID is the device's only ID.
    let app = try #require(contexts["app"] as? [String: Any])
    #expect(app["device_app_hash"] == nil)
    // No automatic breadcrumbs.
    #expect((event["breadcrumbs"] as? [Any] ?? []).isEmpty)
    // The second net: nowhere in the envelope, under any name.
    let text = envelope.items.map { String(decoding: $0.payload, as: UTF8.self) }.joined()
    let zone = TimeZone.current.identifier
    for key in ["timezone", "time_zone", "ip_address", "device_app_hash"] + (zone.contains("/") ? [zone] : []) {
      #expect(!text.contains(key), "The envelope holds \(key).")
    }
  }

  @Test("An event names no install folder: each image's path is its path inside the app's bundle")
  func noInstallFolder() async throws {
    let receiver = try await EnvelopeReceiver.start()
    let place = try Place()
    let diagnostics = place.diagnostics(
      Diagnostics.Build(dsn: receiver.dsn, environment: "test", isDebug: false, hasLaunchArgument: false))
    diagnostics.noticeShown()
    let id = try #require(diagnostics.diagnosticsID)
    // The probe carries the stack of the thread that sends it, with the images of its frames.
    diagnostics.sendProbe()
    await diagnostics.flush()
    diagnostics.isOn = false

    let envelope = try #require(receiver.envelopes.first { !$0.events.isEmpty })
    let event = try #require(envelope.events.first)
    let images = try #require((event["debug_meta"] as? [String: Any])?["images"] as? [[String: Any]])
    let files = images.compactMap { $0["code_file"] as? String }
    // Sentry's JSON holds the threads and the exceptions each in `values`.
    let stacks = ["threads", "exception"].flatMap {
      (event[$0] as? [String: Any])?["values"] as? [[String: Any]] ?? []
    }
    let frames = stacks.flatMap { ($0["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]] ?? [] }
    let packages = frames.compactMap { $0["package"] as? String }
    // The app's own image is there, by its path inside the bundle.
    #expect(files.contains { $0.hasPrefix("Wishbone") }, "\(files)")
    #expect(packages.contains { $0.hasPrefix("Wishbone") }, "\(packages)")
    #expect(!(files + packages).contains { $0.contains(".app/") }, "\(files + packages)")

    // Nowhere in the envelope: the folder that iOS gives the app at install. The check can fail: the text of an
    // envelope reads Sentry's `\/` as `/`.
    let planted = EnvelopeReceiver.envelope(Data(#"{}\#n{"type":"event"}\#n{"code_file":"\/var\/containers\/A"}"#.utf8))
    #expect(planted.text.contains("/var/containers/"))
    // A path that ends at the container's folder keeps no UUID.
    let container = "/private/var/containers/Bundle/Application/\(UUID().uuidString)"
    #expect(Diagnostics.pathInsideBundle(container) == "")
    #expect(Diagnostics.pathInsideBundle(container + "/Wishbone.app/Wishbone") == "Wishbone")
    for folder in ["/containers/", "/var/containers/"] {
      #expect(envelope.text.range(of: folder, options: .caseInsensitive) == nil, "The envelope names \(folder).")
    }
    // The only values shaped like a UUID are the diagnostics ID, the images' debug IDs, and the app's build ID,
    // which is the same in every install of a build.
    let debugIDs = images.compactMap { $0["debug_id"] as? String }
    let appID = ((event["contexts"] as? [String: Any])?["app"] as? [String: Any])?["app_id"] as? String
    let allowed = Set(([id] + debugIDs + [appID].compactMap(\.self)).map { $0.uppercased() })
    let uuid = /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/
    let found = Set(envelope.text.matches(of: uuid).map { String($0.output).uppercased() })
    #expect(found.contains(id.uppercased()))
    #expect(found.subtracting(allowed).isEmpty, "Other UUIDs in the envelope: \(found.subtracting(allowed))")
  }

  @Test("An event's device context has only the device's model and memory, and no state of the device")
  func deviceContext() async throws {
    let receiver = try await EnvelopeReceiver.start()
    let place = try Place()
    let diagnostics = place.diagnostics(
      Diagnostics.Build(dsn: receiver.dsn, environment: "test", isDebug: false, hasLaunchArgument: false))
    diagnostics.noticeShown()
    diagnostics.sendProbe()
    await diagnostics.flush()
    diagnostics.isOn = false

    let envelope = try #require(receiver.envelopes.first { !$0.events.isEmpty })
    let event = try #require(envelope.events.first)
    let contexts = try #require(event["contexts"] as? [String: Any])
    let device = try #require(contexts["device"] as? [String: Any])
    let kept: Set = ["model", "model_id", "family", "arch", "simulator", "memory_size", "free_memory"]
    #expect(Set(device.keys).isSubset(of: kept), "The device context holds \(Set(device.keys).subtracting(kept)).")
    #expect(device["model"] != nil)
    let dropped = [
      "battery_level", "charging", "connection_type", "connection_effective_type", "orientation", "low_power_mode",
      "thermal_state", "screen_width_pixels", "screen_height_pixels", "processor_count", "usable_memory",
      "timezone", "locale",
    ]
    for field in dropped {
      #expect(device[field] == nil, "The device context holds \(field).")
      #expect(!envelope.text.contains("\"\(field)\""), "The envelope holds \(field).")
    }
    #expect((contexts["os"] as? [String: Any])?["rooted"] == nil)
    #expect((contexts["app"] as? [String: Any])?["view_names"] == nil)
    for field in ["rooted", "view_names"] {
      #expect(!envelope.text.contains("\"\(field)\""), "The envelope holds \(field).")
    }
  }

  /// The user of an event, as its fields.
  func user(_ event: [String: Any]) -> [String: String] {
    (event["user"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
  }
}

/// A test's own defaults and folder, which it removes when it goes.
nonisolated final class Place {
  let suite = "DiagnosticsTests-\(UUID().uuidString)"
  let defaults: UserDefaults
  let folder: URL

  init() throws {
    defaults = try #require(UserDefaults(suiteName: suite))
    folder = URL.cachesDirectory.appending(path: suite, directoryHint: .isDirectory)
  }

  deinit {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: folder)
  }

  /// Diagnostics as at a launch of the app, in this place.
  @MainActor func diagnostics(_ build: Diagnostics.Build) -> Diagnostics {
    Diagnostics(build: build, defaults: defaults, folder: folder)
  }

  /// How many envelopes the SDK keeps to send later.
  func unsentEnvelopes() throws -> Int {
    let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
    return (files?.allObjects as? [URL] ?? []).filter {
      $0.pathComponents.contains("envelopes") && !$0.hasDirectoryPath
    }
    .count
  }
}
