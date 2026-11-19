import KernCore

/// The menu bar redraws a status item again for every other display after each change, so the samples of one tick,
/// which reach the main thread milliseconds apart, must be drawn in one pass.
@MainActor
final class SampleBatch {
  private let window: Duration
  private let deliver: (Set<Metric>) -> Void
  private var pending: Set<Metric> = []
  private var delivery: Task<Void, Never>?

  init(window: Duration, deliver: @escaping (Set<Metric>) -> Void) {
    self.window = window
    self.deliver = deliver
  }

  deinit {
    delivery?.cancel()
  }

  func add(_ metric: Metric) {
    pending.insert(metric)

    guard delivery == nil else { return }

    if window <= .zero {
      deliverPending()
      return
    }

    delivery = Task { [weak self, window] in
      do {
        try await Task.sleep(for: window)
      } catch {
        return
      }

      guard !Task.isCancelled else { return }

      self?.deliverPending()
    }
  }

  func cancel() {
    delivery?.cancel()

    delivery = nil
    pending = []
  }

  private func deliverPending() {
    let metrics = pending

    pending = []
    delivery = nil

    deliver(metrics)
  }
}
