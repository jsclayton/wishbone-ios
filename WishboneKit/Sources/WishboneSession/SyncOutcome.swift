/// How a sync ended. Every sync ends in one place, with one of these. See `SessionModel.syncNow()`.
public enum SyncOutcome: Sendable, Equatable {
  /// The sync ran to its end, so the copy is in step with the instance.
  case succeeded

  /// The instance could not be reached. The copy keeps what the sync wrote before it stopped, and screens show it
  /// under the line "Can't reach {address}".
  case unreachable

  /// The sync stopped, or never started: the instance refused, a version block shows, the copy can't be written,
  /// or the session ended. The copy keeps what the sync wrote before it stopped.
  case stopped
}
