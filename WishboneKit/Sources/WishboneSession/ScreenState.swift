/// What a screen behind the tabs shows: its rows from the copy, or one of the states that every screen shares. The
/// session model gives it, from the screen's rows and the outcome of the syncs (see `SessionModel.screenState`).
/// See "What every screen shares" in `docs/screens/README.md`.
public enum ScreenState: Sendable, Equatable {
  /// The screen's rows, from the copy. `cantReach` is whether the line "Can't reach {address}" shows above them.
  case saved(cantReach: Bool)
  /// No rows yet, and no sync has succeeded: the first sync runs, or is about to. The system's progress indicator.
  case loading
  /// No rows yet, and the instance can't be reached: the unreachable state, with Try again. Never an empty state.
  case cantReach
  /// No rows yet, and the first sync reached the instance but failed: the error state, with Try again. Never Loading
  /// forever, and never an empty state. The app goes on syncing on its schedule.
  case firstSyncFailed
  /// No rows, after a sync that succeeded found nothing: the screen's own empty state.
  case empty
}
