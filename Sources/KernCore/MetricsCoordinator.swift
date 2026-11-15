import os

private let logger = Logger(subsystem: "Kern", category: "metrics")

/// Samples each enabled metric on its own schedule while running, and records every sample in `store`.
///
/// Each change to a metric's schedule runs only after the previous change has finished, including any sample it had
/// in progress. A metric therefore never has two schedules or more than one sample waiting to run, however quickly the
/// configuration changes.
@MainActor
public final class MetricsCoordinator<C: Clock<Duration>> {
  private struct Collector {
    let provider: MetricProvider
    var interval: Duration
    var isEnabled = true
    /// The latest change to the schedule. Its value is the tick of the last sample taken, which the next change
    /// needs to keep samples at least one interval apart.
    var lastChange: Task<C.Instant?, Never>?
  }

  public let store: MetricsStore
  public private(set) var isRunning = false
  private var collectors: [Metric: Collector]
  private let clock: C

  init(providers: [Metric: MetricProvider], clock: C) {
    let collectors = Dictionary(
      uniqueKeysWithValues: providers.map { metric, provider in
        (metric, Collector(provider: provider, interval: metric.defaultInterval))
      })

    self.clock = clock
    self.collectors = collectors
    self.store = MetricsStore(intervals: collectors.mapValues(\.interval))
  }

  deinit {
    for collector in collectors.values {
      collector.lastChange?.cancel()
    }
  }

  public func start() {
    guard !isRunning else { return }

    isRunning = true

    for (metric, collector) in collectors where collector.isEnabled {
      begin(metric)
    }
  }

  public func stop() {
    guard isRunning else { return }

    isRunning = false

    for (metric, collector) in collectors where collector.isEnabled {
      end(metric)
    }
  }

  public func enable(_ metric: Metric) {
    guard !collector(metric).isEnabled else { return }

    collectors[metric]?.isEnabled = true

    if isRunning { begin(metric) }
  }

  public func disable(_ metric: Metric) {
    guard collector(metric).isEnabled else { return }

    collectors[metric]?.isEnabled = false

    if isRunning { end(metric) }
  }

  public func setInterval(_ interval: Duration, for metric: Metric) {
    precondition(interval > .zero, "a sampling interval must be positive")

    let collector = collector(metric)

    guard collector.interval != interval else { return }

    collectors[metric]?.interval = interval
    store.setInterval(interval, for: metric)

    if isRunning && collector.isEnabled { retime(metric) }
  }

  private func collector(_ metric: Metric) -> Collector {
    guard let collector = collectors[metric] else { preconditionFailure("no provider for \(metric)") }

    return collector
  }

  private func begin(_ metric: Metric) {
    let collector = collector(metric)
    let collect = collecting(metric)

    enqueue(metric) { [provider = collector.provider, interval = collector.interval] lastTick in
      await provider.start()

      if case .unavailable(let error) = await provider.availability {
        logger.debug("started \(metric.rawValue, privacy: .public), unavailable: \(error, privacy: .public)")
      } else {
        logger.debug("started \(metric.rawValue, privacy: .public), every \(interval, privacy: .public)")
      }

      return await collect(lastTick)
    }
  }

  private func retime(_ metric: Metric) {
    enqueue(metric, collecting(metric))
  }

  private func end(_ metric: Metric) {
    let provider = collector(metric).provider

    enqueue(metric) { lastTick in
      await provider.stop()

      logger.debug("stopped \(metric.rawValue, privacy: .public)")

      return lastTick
    }
  }

  /// Cancels the metric's latest change and runs `change` once it has finished. Cancellation only ends sampling;
  /// starting and stopping the provider always run, so they stay paired.
  private func enqueue(_ metric: Metric, _ change: @escaping @Sendable (_ lastTick: C.Instant?) async -> C.Instant?) {
    let previous = collectors[metric]?.lastChange

    previous?.cancel()

    collectors[metric]?.lastChange = Task {
      await change(await previous?.value ?? nil)
    }
  }

  /// Sampling with the metric's current interval, captured now so that it runs as configured at the time of the
  /// change even though it starts later. Its ticks count from now too, not from when it starts, so that metrics
  /// changed together keep the same ticks however long each provider takes to open, and the menu bar redraws once
  /// for their samples instead of once for each.
  private func collecting(_ metric: Metric) -> @Sendable (_ lastTick: C.Instant?) async -> C.Instant? {
    let collector = collector(metric)
    let requested = clock.now

    return { [provider = collector.provider, interval = collector.interval, store = store, clock = clock] lastTick in
      await Self.collect(
        metric, from: provider, every: interval, after: lastTick, requested: requested, into: store, clock: clock)
    }
  }

  /// Samples `provider` every `interval` until the task is cancelled, and returns the tick of the last sample.
  ///
  /// The first tick is one interval after `lastTick`, or the moment the change was `requested` if that is later.
  /// A sample that starts or ends late drops the ticks it missed instead of catching up, so samples never pile up
  /// behind a slow sensor.
  private nonisolated static func collect(
    _ metric: Metric,
    from provider: MetricProvider,
    every interval: Duration,
    after lastTick: C.Instant?,
    requested: C.Instant,
    into store: MetricsStore,
    clock: C
  ) async -> C.Instant? {
    var lastTick = lastTick
    var tick = lastTick.map { max($0.advanced(by: interval), requested) } ?? requested

    while true {
      do {
        // The tolerance lets macOS coalesce the wakeup with other timers.
        try await clock.sleep(until: tick, tolerance: .milliseconds(100))
      } catch {
        return lastTick
      }

      let sample = await provider.sample()

      await store.record(sample, for: metric)

      lastTick = tick

      if Task.isCancelled { return lastTick }

      let now = clock.now

      repeat {
        tick = tick.advanced(by: interval)
      } while tick < now
    }
  }
}

extension MetricsCoordinator where C == ContinuousClock {
  public convenience init(providers: [Metric: MetricProvider]) {
    self.init(providers: providers, clock: ContinuousClock())
  }
}
