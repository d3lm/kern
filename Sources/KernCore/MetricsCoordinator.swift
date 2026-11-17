import os

private let logger = Logger(subsystem: "Kern", category: "metrics")

@MainActor
public final class MetricsCoordinator<C: Clock<Duration>> {
  static var baselineSpan: Duration { .milliseconds(250) }

  /// The wait between retries of a failing sensor stops doubling before it would exceed this.
  nonisolated static var maximumRetryDelay: Duration { .seconds(60) }

  private struct Collector {
    let provider: MetricProvider
    var configuredInterval: Duration
    var interval: Duration
    var isEnabled = true
    var isScheduled = false
    var lastChange: Task<Progress, Never>?
  }

  /// Each change to a metric's schedule hands this to the next, so the next continues where sampling stood.
  private struct Progress {
    var lastTick: C.Instant?
    var failures = 0
    /// Holds from a sample that only set a baseline until the value that follows it has been read.
    var awaitsValue = false
  }

  public let store: MetricsStore
  public private(set) var isRunning = false

  public var areDetailsVisible = false {
    didSet { updateSchedules() }
  }

  public var powerState = PowerState() {
    didSet {
      if powerState.isLowPowerModeEnabled != oldValue.isLowPowerModeEnabled {
        logger.debug(
          """
          Low Power Mode turned \(self.powerState.isLowPowerModeEnabled ? "on" : "off", privacy: .public), \
          behavior \(self.lowPowerModeBehavior.rawValue, privacy: .public)
          """)

        updateIntervals()
      }

      if powerState.isAsleep != oldValue.isAsleep {
        if powerState.isAsleep {
          logger.debug("suspending sampling, the system is going to sleep")
        } else {
          logger.debug("resuming sampling, the system woke")
          restartTicks()
        }

        updateSchedules()
      }
    }
  }

  public var lowPowerModeBehavior = LowPowerModeBehavior.standard {
    didSet { updateIntervals() }
  }

  private var collectors: [Metric: Collector]
  private let clock: C

  init(providers: [Metric: MetricProvider], clock: C) {
    let collectors = Dictionary(
      uniqueKeysWithValues: providers.map { metric, provider in
        let interval = metric.defaultInterval

        return (metric, Collector(provider: provider, configuredInterval: interval, interval: interval))
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

    collectors[metric]?.configuredInterval = interval
    updateInterval(of: metric)
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

  private func updateIntervals() {
    for metric in collectors.keys {
      updateInterval(of: metric)
    }
  }

  private func updateInterval(of metric: Metric) {
    let collector = collector(metric)
    var interval = collector.configuredInterval

    if powerState.isLowPowerModeEnabled, lowPowerModeBehavior == .adaptive {
      interval = max(interval, metric.lowPowerInterval)
    }

    guard interval != collector.interval else { return }

    collectors[metric]?.interval = interval
    store.setInterval(interval, for: metric)

    if collector.isScheduled {
      logger.debug("retimed \(metric.rawValue, privacy: .public), every \(interval, privacy: .public)")
      retime(metric)
    }
  }

  private func updateSchedules() {
    for metric in collectors.keys {
      updateSchedule(of: metric)
    }
  }

  private func updateSchedule(of metric: Metric) {
    let collector = collector(metric)

    let isWanted =
      isRunning && !powerState.isAsleep && collector.isEnabled
      && (areDetailsVisible || !metric.isSampledOnlyForDetails)

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

    enqueue(metric) { [provider = collector.provider, interval = collector.interval] progress in
      await provider.start()

      if case .unavailable(let error) = await provider.availability {
        logger.debug("started \(metric.rawValue, privacy: .public), unavailable: \(error, privacy: .public)")
      } else {
        logger.debug("started \(metric.rawValue, privacy: .public), every \(interval, privacy: .public)")
      }

      return await collect(Progress(lastTick: progress.lastTick))
    }
  }

  private func retime(_ metric: Metric) {
    enqueue(metric, collecting(metric))
  }

  private func end(_ metric: Metric) {
    let provider = collector(metric).provider

    enqueue(metric) { progress in
      await provider.stop()

      logger.debug("stopped \(metric.rawValue, privacy: .public)")

      return progress
    }
  }

  /// A reading from before the sleep says nothing about the Mac now, and PRD PERF-02 wants sampling back within
  /// 5 seconds of the wake, so no schedule may wait out the rest of its interval.
  private func restartTicks() {
    for metric in collectors.keys {
      enqueue(metric) { _ in Progress() }
    }
  }

  /// Cancellation only ends sampling. Starting and stopping the provider always run, so they stay paired.
  private func enqueue(_ metric: Metric, _ change: @escaping @Sendable (Progress) async -> Progress) {
    let previous = collectors[metric]?.lastChange

    previous?.cancel()

    collectors[metric]?.lastChange = Task {
      await change(await previous?.value ?? Progress())
    }
  }

  /// Read `requested` here, not in the closure, so metrics changed together share ticks and redraw once.
  private func collecting(_ metric: Metric) -> @Sendable (Progress) async -> Progress {
    let collector = collector(metric)
    let requested = clock.now

    return { [provider = collector.provider, interval = collector.interval, store = store, clock = clock] progress in
      await Self.collect(
        metric, from: provider, every: interval, after: progress, requested: requested, into: store, clock: clock)
    }
  }

  private nonisolated static func collect(
    _ metric: Metric,
    from provider: MetricProvider,
    every interval: Duration,
    after progress: Progress,
    requested: C.Instant,
    into store: MetricsStore,
    clock: C
  ) async -> Progress {
    var progress = progress

    var tick =
      progress.lastTick.map { lastTick in
        max(lastTick.advanced(by: retryDelay(after: progress.failures, every: interval)), requested)
      } ?? requested

    func take() async -> MetricSample {
      let sample = await provider.sample()

      await store.record(sample, for: metric)

      progress.failures = failuresInARow(after: sample, following: progress.failures, of: metric, every: interval)

      return sample
    }

    /// Returns `false` when the schedule ended before the value was read.
    func readAwaitedValue() async -> Bool {
      do {
        try await clock.sleep(for: baselineSpan)
      } catch {
        return false
      }

      _ = await take()
      progress.awaitsValue = false

      return !Task.isCancelled
    }

    func dropMissedTicks() {
      let now = clock.now

      while tick < now {
        tick = tick.advanced(by: interval)
      }
    }

    // a change of interval can end the schedule that took a baseline before it has read the value
    if progress.awaitsValue {
      guard await readAwaitedValue() else { return progress }

      dropMissedTicks()
    }

    while true {
      do {
        try await clock.sleep(until: tick, tolerance: .milliseconds(100))
      } catch {
        return progress
      }

      // a sensor that failed to open stays closed until its provider is started again, and starting a provider
      // whose sensor is open does nothing
      if progress.failures > 0 {
        await provider.start()
      }

      let sample = await take()

      progress.lastTick = tick
      progress.awaitsValue = sample.state == .unavailable(.noValue(.awaitingBaseline))

      if Task.isCancelled { return progress }

      if progress.awaitsValue {
        guard await readAwaitedValue() else { return progress }
      }

      tick = tick.advanced(by: retryDelay(after: progress.failures, every: interval))
      dropMissedTicks()
    }
  }

  private nonisolated static func failuresInARow(
    after sample: MetricSample,
    following earlier: Int,
    of metric: Metric,
    every interval: Duration
  ) -> Int {
    guard case .unavailable(.sensorFailed(let error)) = sample.state else {
      if earlier > 0 {
        logger.debug("\(metric.rawValue, privacy: .public) recovered after \(earlier) failed attempts")
      }

      return 0
    }

    let failures = earlier + 1
    let delay = retryDelay(after: failures, every: interval)

    logger.debug(
      """
      \(metric.rawValue, privacy: .public) failed, retry \(failures) in \(delay, privacy: .public): \
      \(error, privacy: .public)
      """)

    return failures
  }

  /// Returns the wait after `failures` failed samples in a row, which is one interval after the first.
  /// It is  always a whole number of intervals, so retries stay on the ticks the metric shares with others.
  nonisolated static func retryDelay(after failures: Int, every interval: Duration) -> Duration {
    var delay = interval

    for _ in 1..<max(failures, 1) {
      guard delay * 2 <= maximumRetryDelay else { break }

      delay *= 2
    }

    return delay
  }
}

extension MetricsCoordinator where C == ContinuousClock {
  public convenience init(providers: [Metric: MetricProvider]) {
    self.init(providers: providers, clock: ContinuousClock())
  }
}
