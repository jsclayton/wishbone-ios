import SwiftUI
import WishboneSession

extension View {
  /// Tells the session model each time this window comes to the foreground, and when it leaves it or closes. So the
  /// session syncs at each foreground, and its timer runs while any window is in the foreground. See "When the app
  /// syncs" in `docs/spec.md`.
  func reportsForeground(to session: SessionModel) -> some View {
    modifier(ForegroundReport(session: session))
  }
}

private struct ForegroundReport: ViewModifier {
  let session: SessionModel

  /// The phase of this window's scene.
  @Environment(\.scenePhase) private var phase

  /// The window's own ID, the same for as long as the window shows the session.
  @State private var window = UUID()

  func body(content: Content) -> some View {
    content
      // A change of phase cancels the work of the last one. Each task says where the window is before it waits, and
      // the tasks start in the order of the changes, so the last phase wins.
      .task(id: phase) {
        if phase == .active {
          await session.cameToForeground(window: window)
        } else {
          session.leftForeground(window: window)
        }
      }
      .onDisappear { session.leftForeground(window: window) }
  }
}
