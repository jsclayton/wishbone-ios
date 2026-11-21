import Observation

/// Returns when what the model publishes meets the condition. It waits for the model to change, never for a
/// length of time. The suite's time limit ends a wait for something that never comes.
@MainActor
func until(_ condition: @escaping @MainActor @Sendable () -> Bool) async {
  for await isMet in Observations({ condition() }) where isMet {
    return
  }
}
