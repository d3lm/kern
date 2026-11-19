import os

private let logger = Logger(subsystem: "Kern", category: "metrics")

@MainActor
public final class MetricsCoordinator<C: Clock<Duration>> {
  nonisolated static var baselineSpan: Duration { .milliseconds(250) }

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
    /// Holds the tick the most recent attempt to sample was scheduled for, which a retry waits out its delay from.
    var lastTick: C.Instant?
    /// Holds the instant the most recent sample was read, which the next tick is planned from.
    var lastSampled: C.Instant?
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
  /// Anchors every metric's tick grid so schedules added or retimed later stay in phase with running ones.
  private var epoch: C.Instant?

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

    store.setEnabled(true, for: metric)
    updateSchedule(of: metric, at: clock.now)
  }

  /// Also empties the metric's readings in the store, which records none of its samples until it is enabled again.
  public func disable(_ metric: Metric) {
    collectors[metric]?.isEnabled = false

    store.setEnabled(false, for: metric)
    updateSchedule(of: metric, at: clock.now)
  }

  /// Keeps the most recent samples of each history that fit the new capacity.
  public func setHistoryCapacity(_ capacity: Int) {
    store.setHistoryCapacity(capacity)
  }

  public func setInterval(_ interval: Duration, for metric: Metric) {
    precondition(interval > .zero, "a sampling interval must be positive")

    collectors[metric]?.configuredInterval = interval

    updateInterval(of: metric, at: clock.now)
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
    let now = clock.now

    for metric in collectors.keys {
      updateInterval(of: metric, at: now)
    }
  }

  private func updateInterval(of metric: Metric, at now: C.Instant) {
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
      retime(metric, at: now)
    }
  }

  private func updateSchedules() {
    let now = clock.now

    for metric in collectors.keys {
      updateSchedule(of: metric, at: now)
    }
  }

  private func updateSchedule(of metric: Metric, at now: C.Instant) {
    let collector = collector(metric)

    let isWanted =
      isRunning && !powerState.isAsleep && collector.isEnabled
      && (areDetailsVisible || !metric.isSampledOnlyForDetails)

    guard isWanted != collector.isScheduled else { return }

    collectors[metric]?.isScheduled = isWanted

    if isWanted {
      begin(metric, at: now)
    } else {
      end(metric)

      if collectors.values.allSatisfy({ !$0.isScheduled }) {
        epoch = nil
      }
    }
  }

  private func begin(_ metric: Metric, at now: C.Instant) {
    let collector = collector(metric)
    let collect = collecting(metric, at: now)

    enqueue(metric) { [provider = collector.provider, interval = collector.interval] progress in
      await provider.start()

      if case .unavailable(let error) = await provider.availability {
        logger.debug("started \(metric.rawValue, privacy: .public), unavailable: \(error, privacy: .public)")
      } else {
        logger.debug("started \(metric.rawValue, privacy: .public), every \(interval, privacy: .public)")
      }

      return await collect(Progress(lastSampled: progress.lastSampled))
    }
  }

  private func retime(_ metric: Metric, at now: C.Instant) {
    enqueue(metric, collecting(metric, at: now))
  }

  private func end(_ metric: Metric) {
    let provider = collector(metric).provider

    enqueue(metric) { progress in
      await provider.stop()

      logger.debug("stopped \(metric.rawValue, privacy: .public)")

      return progress
    }
  }

  private func restartTicks() {
    epoch = nil

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

  /// Passes the shared `epoch` captured when scheduling began so metrics added or retimed later snap onto the same
  /// tick grid and batch into one menu-bar redraw.
  private func collecting(_ metric: Metric, at requested: C.Instant) -> @Sendable (Progress) async -> Progress {
    let collector = collector(metric)
    let epoch = self.epoch ?? requested

    self.epoch = epoch

    return { [provider = collector.provider, interval = collector.interval, store = store, clock = clock] progress in
      await Self.collect(
        metric, from: provider, every: interval, after: progress, requested: requested, epoch: epoch, into: store,
        clock: clock)
    }
  }

  private nonisolated static func collect(
    _ metric: Metric,
    from provider: MetricProvider,
    every interval: Duration,
    after progress: Progress,
    requested: C.Instant,
    epoch: C.Instant,
    into store: MetricsStore,
    clock: C
  ) async -> Progress {
    var progress = progress

    func take() async -> MetricSample {
      let sample = await provider.sample()

      progress.lastSampled = clock.now

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

    /// Returns the first tick on the shared grid at least `baselineSpan` after the sample read at `sampled`, so no rate
    /// is read over a shorter window than its first value. A value read off the grid is therefore followed within one
    /// interval plus `baselineSpan`, which keeps the retry after one failed sample inside the margin of
    /// `MetricReadings.staleAt`. After a failure the tick also waits out the retry delay from the tick that failed.
    func nextTick(after sampled: C.Instant) -> C.Instant {
      var earliest = sampled.advanced(by: baselineSpan)

      if progress.failures > 0, let lastTick = progress.lastTick {
        earliest = max(earliest, lastTick.advanced(by: retryDelay(after: progress.failures, every: interval)))
      }

      return aligned(atOrAfter: earliest, from: epoch, every: interval)
    }

    // a change of interval can end the schedule that took a baseline before it has read the value
    if progress.awaitsValue {
      guard await readAwaitedValue() else { return progress }
    }

    var tick = progress.lastSampled.map { max(nextTick(after: $0), requested) } ?? requested

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

      progress.lastTick = tick

      let sample = await take()

      progress.awaitsValue = sample.state == .unavailable(.noValue(.awaitingBaseline))

      if Task.isCancelled { return progress }

      if progress.awaitsValue {
        guard await readAwaitedValue() else { return progress }
      }

      tick = nextTick(after: clock.now)
    }
  }

  /// Returns the earliest instant on the `epoch + k * interval` grid that is at or after `instant`.
  private nonisolated static func aligned(
    atOrAfter instant: C.Instant,
    from epoch: C.Instant,
    every interval: Duration
  ) -> C.Instant {
    let elapsed = epoch.duration(to: instant)

    guard elapsed > .zero else { return epoch }

    let attosecondsPerSecond: Int128 = 1_000_000_000_000_000_000

    let elapsedAtto =
      Int128(elapsed.components.seconds) * attosecondsPerSecond + Int128(elapsed.components.attoseconds)

    let intervalAtto =
      Int128(interval.components.seconds) * attosecondsPerSecond + Int128(interval.components.attoseconds)

    let steps = (elapsedAtto + intervalAtto - 1) / intervalAtto
    let (seconds, attoseconds) = (steps * intervalAtto).quotientAndRemainder(dividingBy: attosecondsPerSecond)

    return epoch.advanced(by: Duration(secondsComponent: Int64(seconds), attosecondsComponent: Int64(attoseconds)))
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
  /// It is always a whole number of intervals, so retries stay on the ticks the metric shares with others.
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
