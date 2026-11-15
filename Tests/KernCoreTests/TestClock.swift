import Synchronization
import Testing

/// A clock that moves only when a test advances it, so schedules can be checked without waiting for them.
final class TestClock: Clock, Sendable {
  struct Instant: InstantProtocol {
    let offset: Swift.Duration

    func advanced(by duration: Swift.Duration) -> Instant {
      Instant(offset: offset + duration)
    }

    func duration(to other: Instant) -> Swift.Duration {
      other.offset - offset
    }

    static func < (lhs: Instant, rhs: Instant) -> Bool {
      lhs.offset < rhs.offset
    }
  }

  private struct Sleeper {
    let deadline: Instant
    let continuation: CheckedContinuation<Void, any Error>
  }

  private struct State {
    var now = Instant(offset: .zero)
    var sleepers: [Int: Sleeper] = [:]
    var nextSleeperID = 0
  }

  private let state = Mutex(State())

  var now: Instant { state.withLock { $0.now } }

  var minimumResolution: Swift.Duration { .zero }

  /// Every pending `sleep`. Once all scheduled work has run, this is one per running schedule.
  var sleeperCount: Int { state.withLock { $0.sleepers.count } }

  /// Whole seconds since the clock was created.
  var seconds: Int { Int(now.offset.components.seconds) }

  func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
    let id = state.withLock { state in
      defer { state.nextSleeperID += 1 }

      return state.nextSleeperID
    }

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let immediateResult: Result<Void, any Error>? = state.withLock { state in
          if Task.isCancelled { return .failure(CancellationError()) }
          if deadline <= state.now { return .success(()) }

          state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)

          return nil
        }

        if let immediateResult { continuation.resume(with: immediateResult) }
      }
    } onCancel: {
      state.withLock { $0.sleepers.removeValue(forKey: id) }?.continuation.resume(throwing: CancellationError())
    }
  }

  /// Wakes every sleeper whose deadline has been reached. Safe to call from any thread, including from inside a sensor
  /// read, which is how a test makes a sample take time.
  func advance(by duration: Swift.Duration) {
    let due = state.withLock { state in
      state.now = state.now.advanced(by: duration)

      let due = state.sleepers.filter { $0.value.deadline <= state.now }

      for id in due.keys { state.sleepers[id] = nil }

      return due.values
    }

    for sleeper in due { sleeper.continuation.resume() }
  }
}

/// Waits in real time for work the test cannot await directly, such as a schedule going back to sleep after it was
/// woken. Records an issue instead of hanging when the condition never holds.
@MainActor
func waitUntil(
  _ condition: () -> Bool,
  sourceLocation: SourceLocation = #_sourceLocation
) async {
  let deadline = ContinuousClock.now + .seconds(5)

  while !condition() {
    guard ContinuousClock.now < deadline else {
      Issue.record("condition still false after 5 seconds", sourceLocation: sourceLocation)
      return
    }

    try? await Task.sleep(for: .milliseconds(1))
  }
}
