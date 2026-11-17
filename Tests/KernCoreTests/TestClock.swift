import Synchronization
import Testing

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

  var sleeperCount: Int { state.withLock { $0.sleepers.count } }

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

/// Gives up after 2,500 checks, which take a few seconds while the main thread is free. The wait counts
/// checks, not seconds, because every main-actor test shares the main thread, and while other tests keep
/// it busy the condition can neither become true nor be checked.
@MainActor
func waitUntil(
  _ condition: () -> Bool,
  sourceLocation: SourceLocation = #_sourceLocation
) async {
  for _ in 0..<2_500 {
    if condition() { return }

    try? await Task.sleep(for: .milliseconds(1))
  }

  if !condition() {
    Issue.record("condition still false after 2,500 checks", sourceLocation: sourceLocation)
  }
}
