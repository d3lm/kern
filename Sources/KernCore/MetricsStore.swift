public struct MetricReadings: Sendable {
  public internal(set) var interval: Duration
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
}

@MainActor
public final class MetricsStore {
  public struct ObserverID: Hashable, Sendable {
    fileprivate let rawValue: Int
  }

  public nonisolated static let historyCapacity = 60

  private var readings: [Metric: MetricReadings]
  private var observers: [ObserverID: @MainActor (Metric) -> Void] = [:]
  private var nextObserverID = 0

  init(intervals: [Metric: Duration]) {
    readings = Dictionary(
      uniqueKeysWithValues: intervals.map { metric, interval in
        let history = metric.keepsHistory ? SampleHistory(capacity: Self.historyCapacity) : nil

        return (metric, MetricReadings(interval: interval, history: history))
      })
  }

  public subscript(metric: Metric) -> MetricReadings? {
    readings[metric]
  }

  public func observe(_ observer: @escaping @MainActor (Metric) -> Void) -> ObserverID {
    let id = ObserverID(rawValue: nextObserverID)

    nextObserverID += 1
    observers[id] = observer

    return id
  }

  public func removeObserver(_ id: ObserverID) {
    observers[id] = nil
  }

  func record(_ sample: MetricSample, for metric: Metric) {
    precondition(readings[metric] != nil, "the store has no readings for \(metric)")

    readings[metric]?.record(sample)

    for observer in observers.values {
      observer(metric)
    }
  }

  func setInterval(_ interval: Duration, for metric: Metric) {
    precondition(readings[metric] != nil, "the store has no readings for \(metric)")

    readings[metric]?.interval = interval
  }
}
