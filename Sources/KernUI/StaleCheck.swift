@MainActor
final class StaleCheck {
  typealias Sleep = @Sendable (_ until: ContinuousClock.Instant) async throws -> Void

  nonisolated static let sleepUntilDeadline: Sleep = { deadline in
    try await Task.sleep(until: deadline, tolerance: .milliseconds(500), clock: .continuous)
  }

  private let sleep: Sleep
  private let markStale: @MainActor () -> Void
  private var pending: (deadline: ContinuousClock.Instant, task: Task<Void, Never>)?

  init(sleep: @escaping Sleep = sleepUntilDeadline, markStale: @escaping @MainActor () -> Void) {
    self.sleep = sleep
    self.markStale = markStale
  }

  func schedule(at deadline: ContinuousClock.Instant?) {
    guard deadline != pending?.deadline else { return }

    pending?.task.cancel()
    pending = nil

    guard let deadline else { return }

    let task = Task { [weak self, sleep] in
      do {
        try await sleep(deadline)
      } catch {
        return
      }

      self?.fire(dueAt: deadline)
    }

    pending = (deadline, task)
  }

  /// Cancelling a check that has already woken does not stop it, so only the check for the current deadline may
  /// mark the value stale.
  private func fire(dueAt deadline: ContinuousClock.Instant) {
    guard pending?.deadline == deadline else { return }

    pending = nil

    markStale()
  }

  deinit {
    pending?.task.cancel()
  }
}
