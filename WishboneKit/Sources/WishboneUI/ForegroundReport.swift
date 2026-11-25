import SwiftUI
import WishboneSession

extension View {
  /// Tells the session model each time this window comes to the foreground, and when it leaves it or closes. So the
  /// session syncs at each foreground, and its timer runs while any window is in the foreground. See "When the app
  /// syncs" in `docs/spec.md`.
  ///
  /// The window shows the late refusals that waited, in one alert, when it is the one that came to the foreground.
  /// The alert stays in the window while it is only inactive, and moves only when the window goes to the background
  /// or closes. See "Late refusals" in `docs/spec.md`.
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
        switch phase {
        case .active: await session.cameToForeground(window: window)
        case .inactive: session.leftForeground(window: window)
        default: session.wentToBackground(window: window)
        }
      }
      .onDisappear { session.wentToBackground(window: window) }
      // The late refusals that waited show once, in the window that came to the foreground. Only this window's own
      // alert closes here: when the alert has moved on, the false that SwiftUI writes back as it goes changes nothing.
      .alert(
        Text("Some changes couldn't be saved", bundle: #bundle),
        isPresented: Binding {
          session.lateRefusalAlert?.window == window
        } set: { isPresented in
          if !isPresented { session.lateRefusalsShown(in: window) }
        }
      ) {
        Button {
          session.lateRefusalsShown(in: window)
        } label: {
          Text("OK", bundle: #bundle)
        }
      } message: {
        Text(LateRefusalWords.message(session.lateRefusalAlert?.refusals ?? []))
      }
  }
}
