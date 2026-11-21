import Observation
import SwiftUI
import Testing
import UIKit
import WishboneAPI
import WishboneSession
import WishboneUI

/// Each window tells the session when it comes to the foreground and when it leaves it, and the timer that syncs
/// every 60 seconds runs while any window is in the foreground. See "When the app syncs" in `docs/spec.md`.
@Suite("Windows in the foreground", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct WindowsInForegroundTests {
  @Test("With two windows, the timer runs while either is in the foreground, and stops when the last one leaves it")
  func timerFollowsTheWindows() async throws {
    let instance = try await StandInInstance.start()
    let clock = ManualClock()
    let device = try signedInDevice(on: instance, timerClock: clock)
    let first = try PhasedWindow(device: device)
    let second = try PhasedWindow(device: device)

    // Neither window is in the foreground: the timer doesn't run.
    #expect(clock.sleeperCount == 0)

    // The first comes to the foreground: it syncs, and the timer runs.
    first.phase = .active
    await until { instance.pullCount == 1 && clock.sleeperCount == 1 }

    // The second comes too, and the first leaves. The second still holds the timer: a minute brings a sync.
    second.phase = .active
    await until { instance.pullCount == 2 }
    first.phase = .background
    clock.advance(by: .seconds(60))
    await until { instance.pullCount == 3 && clock.sleeperCount == 1 }

    // The last window leaves the foreground: the timer stops, and a minute brings nothing.
    second.phase = .background
    await until { clock.sleeperCount == 0 }
    clock.advance(by: .seconds(60 * 5))
    try await #require(device.session).syncNow()
    #expect(instance.pullCount == 4)
  }
}

/// A window of the app, as the app's window scene makes it, in a phase that the test sets.
@MainActor
private final class PhasedWindow {
  @Observable
  @MainActor
  final class Phase {
    var value = SwiftUI.ScenePhase.background
  }

  struct Root: View {
    let device: Device
    let phase: Phase

    var body: some View {
      WindowRoot()
        .environment(device)
        .environment(\.scenePhase, phase.value)
    }
  }

  private let state = Phase()
  private let window: UIWindow

  /// The phase of the window's scene.
  var phase: SwiftUI.ScenePhase {
    get { state.value }
    set { state.value = newValue }
  }

  init(device: Device) throws {
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    window = UIWindow(windowScene: scene)
    window.rootViewController = UIHostingController(rootView: Root(device: device, phase: state))
    window.makeKeyAndVisible()
  }

  deinit {
    let window = window
    Task { @MainActor in window.isHidden = true }
  }
}
