import os

private let logger = Logger(subsystem: "Kern", category: "metrics")

public struct MetricReadings: Sendable {
  public internal(set) var interval: Duration
  /// The readings are empty and record no samples while it is false.
  public private(set) var isEnabled = true
  public private(set) var latest: MetricSample?
  public private(set) var lastSuccessful: MetricSample?
  public private(set) var history: SampleHistory?

  init(interval: Duration, history: SampleHistory?) {
    self.interval = interval
    self.history = history
  }

  /// The margin lets one failed or late sample pass without marking the value stale.
  public var staleAt: ContinuousClock.Instant? {
    lastSuccessful.map { $0.acquiredAt + interval * 2 + .seconds(1) }
  }

  public func isStale(at now: ContinuousClock.Instant) -> Bool {
    guard let staleAt else { return false }

    return now >= staleAt
  }

  mutating func record(_ sample: MetricSample) {
    latest = sample

    if sample.value != nil {
      lastSuccessful = sample
    }

    history?.append(sample)
  }

  mutating func setEnabled(_ isEnabled: Bool) {
    self.isEnabled = isEnabled
    latest = nil
    lastSuccessful = nil
    history = history.map { SampleHistory(capacity: $0.capacity) }
  }

  mutating func resizeHistory(to capacity: Int) {
    history = history?.resized(to: capacity)
  }
}

@MainActor
public final class MetricsStore {
  public struct ObserverID: Hashable, Sendable {
    fileprivate let rawValue: Int
  }

  public nonisolated static let defaultHistoryCapacity = 60

  private(set) var historyCapacity = defaultHistoryCapacity
  private var readings: [Metric: MetricReadings]
  private var observers: [ObserverID: @MainActor (Metric) -> Void] = [:]
  private var nextObserverID = 0

  init(intervals: [Metric: Duration]) {
    readings = Dictionary(
      uniqueKeysWithValues: intervals.map { metric, interval in
        let history = metric.keepsHistory ? SampleHistory(capacity: Self.defaultHistoryCapacity) : nil

        return (metric, MetricReadings(interval: interval, history: history))
      })
  }

  public subscript(metric: Metric) -> MetricReadings? {
    readings[metric]
  }

  /// Calls `observer` after every change to a metric's readings, which a sample, a new interval, turning the
  /// metric on or off, and a new history capacity make.
  public func observe(_ observer: @escaping @MainActor (Metric) -> Void) -> ObserverID {
    let id = ObserverID(rawValue: nextObserverID)

    nextObserverID += 1
    observers[id] = observer

    return id
  }

  public func removeObserver(_ id: ObserverID) {
    observers[id] = nil
  }

  /// Drops a sample of a metric that is turned off, because a read in flight when it was turned off
  /// still delivers one.
  func record(_ sample: MetricSample, for metric: Metric) {
    precondition(readings[metric] != nil, "the store has no readings for \(metric)")

    guard readings[metric]?.isEnabled == true else { return }

    readings[metric]?.record(sample)
    logger.debug("sampled \(metric.rawValue, privacy: .public)")
    notifyObservers(of: metric)
  }

  func setInterval(_ interval: Duration, for metric: Metric) {
    precondition(readings[metric] != nil, "the store has no readings for \(metric)")

    guard readings[metric]?.interval != interval else { return }

    readings[metric]?.interval = interval

    notifyObservers(of: metric)
  }

  func setEnabled(_ isEnabled: Bool, for metric: Metric) {
    guard readings[metric]?.isEnabled == !isEnabled else { return }

    readings[metric]?.setEnabled(isEnabled)
    notifyObservers(of: metric)
  }

  func setHistoryCapacity(_ capacity: Int) {
    precondition(capacity > 0, "a history must hold at least one sample")

    guard capacity != historyCapacity else { return }

    historyCapacity = capacity

    for metric in readings.keys where readings[metric]?.history != nil {
      readings[metric]?.resizeHistory(to: capacity)
      notifyObservers(of: metric)
    }
  }

  private func notifyObservers(of metric: Metric) {
    for observer in observers.values {
      observer(metric)
    }
  }
}
