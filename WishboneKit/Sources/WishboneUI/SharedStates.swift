import SwiftUI
import WishboneAPI
import WishboneSession

/// The states that every screen behind the tabs shares: Loading, Can't reach, and Empty, with the line "Can't reach
/// {address}" above saved rows. See "What every screen shares" in `docs/screens/README.md`.
///
/// **Provisional.** Plain default: the line is a row pinned under the navigation bar, the unreachable state and each
/// empty state use the system's unavailable-content view, and Try again is its button.
extension View {
  /// Shows the screen's state over the screen, which holds the rows: the session model decides it from whether the
  /// screen has rows. `empty` is the screen's own empty state, in its own words.
  public func sharedStates(
    of session: SessionModel, hasRows: Bool, @ViewBuilder empty: () -> some View
  ) -> some View {
    sharedStates(
      session.screenState(hasRows: hasRows), address: session.session.instance,
      unsentChanges: session.unsentChangeCount, tryAgain: { await session.syncNow() }, empty: empty)
  }

  /// Shows the state over the screen. Try again runs `tryAgain`, which is Sync now. While unsent changes wait, the
  /// line "Can't reach {address}" says how many.
  public func sharedStates(
    _ state: ScreenState, address: InstanceAddress, unsentChanges: Int = 0,
    tryAgain: @escaping @MainActor () async -> Void, @ViewBuilder empty: () -> some View
  ) -> some View {
    modifier(
      SharedStates(
        state: state, address: address, unsentChanges: unsentChanges, tryAgain: tryAgain, empty: empty()))
  }

  /// Pins the line "Can't reach {address}" under the navigation bar while the last sync found the instance
  /// unreachable, for a screen that has no state of its own to show.
  public func cantReachLine(of session: SessionModel) -> some View {
    sharedStates(
      .saved(cantReach: session.isInstanceUnreachable), address: session.session.instance,
      unsentChanges: session.unsentChangeCount, tryAgain: {}
    ) {
      EmptyView()
    }
  }
}

/// The words "Can't reach {address}", of the line, of the unreachable state, and of what VoiceOver says when the
/// instance can't be reached.
public enum CantReach {
  public static func words(for address: InstanceAddress) -> String {
    String(localized: "Can't reach \(address.text)", bundle: #bundle)
  }

  /// "{n} changes will be sent when it's back.": what the line adds while unsent changes wait. See "Unsent changes,
  /// sign-out, and late refusals" in `docs/spec.md`.
  public static func unsentChanges(_ count: Int) -> String {
    String(localized: "\(count) changes will be sent when it's back.", bundle: #bundle)
  }
}

private struct SharedStates<Empty: View>: ViewModifier {
  let state: ScreenState
  let address: InstanceAddress
  let unsentChanges: Int
  let tryAgain: @MainActor () async -> Void
  let empty: Empty

  func body(content: Content) -> some View {
    content
      .safeAreaInset(edge: .top, spacing: 0) {
        if state == .saved(cantReach: true) {
          CantReachLine(address: address, unsentChanges: unsentChanges)
        }
      }
      .overlay {
        switch state {
        case .saved: EmptyView()
        case .loading: ProgressView()
        case .cantReach: CantReachView(address: address, tryAgain: tryAgain)
        case .empty: empty
        }
      }
  }
}

/// The line "Can't reach {address}": a row pinned under the navigation bar. It blocks nothing. While unsent changes
/// wait, it says how many under the address. It is one element, and at the largest text sizes it wraps, so the
/// address is never cut short.
private struct CantReachLine: View {
  let address: InstanceAddress
  let unsentChanges: Int

  var body: some View {
    VStack(spacing: 2) {
      Text(CantReach.words(for: address))
      if unsentChanges > 0 {
        Text(CantReach.unsentChanges(unsentChanges))
      }
    }
    .multilineTextAlignment(.center)
    .font(.footnote)
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity)
    .padding(.horizontal)
    .padding(.vertical, 8)
    // A solid background, so the text has its full contrast over whatever scrolls under it.
    .background(.background.secondary, ignoresSafeAreaEdges: [])
    .accessibilityElement(children: .combine)
  }
}

/// The unreachable state of a screen with no rows yet: never an empty state. Try again is Sync now.
///
/// As the version block does, the view grows to its words in a scroll view, and Try again is under it: the
/// unavailable view's own actions cut a larger text short.
private struct CantReachView: View {
  let address: InstanceAddress
  let tryAgain: @MainActor () async -> Void

  var body: some View {
    GeometryReader { window in
      ScrollView {
        VStack(spacing: 16) {
          ContentUnavailableView {
            Label {
              Text(CantReach.words(for: address))
            } icon: {
              Image(systemName: "wifi.slash")
            }
          }
          .fixedSize(horizontal: false, vertical: true)

          Button {
            Task { await tryAgain() }
          } label: {
            Text("Try again", bundle: #bundle)
              .frame(minHeight: 44)
          }
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: window.size.height)
      }
    }
  }
}
