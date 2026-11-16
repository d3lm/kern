import os

private let logger = Logger(subsystem: "Kern", category: "metrics")

@MainActor
public final class MetricsCoordinator<C: Clock<Duration>> {
  static var baselineSpan: Duration { .milliseconds(250) }

  private struct Collector {
    let provider: MetricProvider
    var interval: Duration
    var isEnabled = true
    var isScheduled = false
    var lastChange: Task<C.Instant?, Never>?
  }

  public let store: MetricsStore
  public private(set) var isRunning = false

  public var areDetailsVisible = false {
    didSet { updateSchedules() }
  }

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
    isRunning = true
    updateSchedules()
  }

  public func stop() {
    isRunning = false
    updateSchedules()
  }

  public func enable(_ metric: Metric) {
    collectors[metric]?.isEnabled = true
    updateSchedule(of: metric)
  }

  public func disable(_ metric: Metric) {
    collectors[metric]?.isEnabled = false
    updateSchedule(of: metric)
  }

  public func setInterval(_ interval: Duration, for metric: Metric) {
    precondition(interval > .zero, "a sampling interval must be positive")

    let collector = collector(metric)

    guard collector.interval != interval else { return }

    collectors[metric]?.interval = interval
    store.setInterval(interval, for: metric)

    if collector.isScheduled { retime(metric) }
  }

  public func source(of metric: Metric) -> MetricSource {
    let provider = collector(metric).provider

    return MetricSource(
      id: provider.source, quantity: provider.quantity, description: provider.sourceDescription,
      coreKinds: provider.coreKinds)
  }

  private func collector(_ metric: Metric) -> Collector {
    guard let collector = collectors[metric] else { preconditionFailure("no provider for \(metric)") }

    return collector
  }

  private func updateSchedules() {
    for metric in collectors.keys {
      updateSchedule(of: metric)
    }
  }

  private func updateSchedule(of metric: Metric) {
    let collector = collector(metric)
    let isWanted = isRunning && collector.isEnabled && (areDetailsVisible || !metric.isSampledOnlyForDetails)

    guard isWanted != collector.isScheduled else { return }

    collectors[metric]?.isScheduled = isWanted

    if isWanted {
      begin(metric)
    } else {
      end(metric)
    }
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

  /// Cancellation only ends sampling; starting and stopping the provider always run, so they stay paired.
  private func enqueue(_ metric: Metric, _ change: @escaping @Sendable (_ lastTick: C.Instant?) async -> C.Instant?) {
    let previous = collectors[metric]?.lastChange

    previous?.cancel()

    collectors[metric]?.lastChange = Task {
      await change(await previous?.value ?? nil)
    }
  }

  /// Read `requested` here, not in the closure, so metrics changed together share ticks and redraw once.
  private func collecting(_ metric: Metric) -> @Sendable (_ lastTick: C.Instant?) async -> C.Instant? {
    let collector = collector(metric)
    let requested = clock.now

    return { [provider = collector.provider, interval = collector.interval, store = store, clock = clock] lastTick in
      await Self.collect(
        metric, from: provider, every: interval, after: lastTick, requested: requested, into: store, clock: clock)
    }
  }

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
        try await clock.sleep(until: tick, tolerance: .milliseconds(100))
      } catch {
        return lastTick
      }

      let sample = await provider.sample()

      await store.record(sample, for: metric)

      lastTick = tick

      if Task.isCancelled { return lastTick }

      if sample.state == .unavailable(.noValue(.awaitingBaseline)) {
        do {
          try await clock.sleep(for: baselineSpan)
        } catch {
          return lastTick
        }

        await store.record(await provider.sample(), for: metric)

        if Task.isCancelled { return lastTick }
      }

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
