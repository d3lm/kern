import KernCore

/// Collects the metrics that received a sample and delivers them together, `window` after the first of them.
///
/// Every redraw of a status item makes the menu bar redraw the whole item again for each other display, so samples
/// taken at the same tick should be drawn in one pass. They reach the main thread a few milliseconds apart, because
/// some sensors take longer to read than others.
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

  func add(_ metric: Metric) {
    pending.insert(metric)

    guard delivery == nil else { return }

    delivery = Task { [weak self, window] in
      try? await Task.sleep(for: window)

      self?.deliverPending()
    }
  }

  private func deliverPending() {
    let metrics = pending

    pending = []
    delivery = nil

    deliver(metrics)
  }
}
