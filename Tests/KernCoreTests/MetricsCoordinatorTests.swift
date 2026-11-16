import Darwin
import Dispatch
import Testing

@testable import KernCore

struct ClockedSensor: MetricSensor {
  let source = SourceID("test.clocked")
  let quantity = MetricQuantity.utilization
  let sourceDescription = "The test clock's seconds"
  let coreKinds: [CoreKind]? = nil
  let log: SensorLog
  let clock: TestClock
  var failure: SensorError?
  var failsToOpen = false
  var baselineReads = 0
  var whileOpening: [@Sendable () -> Void] = []
  var whileReading: [@Sendable () -> Void] = []

  mutating func open() throws(SensorError) {
    log.record("open")

    if !whileOpening.isEmpty { whileOpening.removeFirst()() }

    if failsToOpen { throw SensorError("cannot open") }
  }

  mutating func read() throws(SensorError) -> SensorReading {
    log.record("read \(clock.seconds)")

    if !whileReading.isEmpty { whileReading.removeFirst()() }
    if let failure { throw failure }

    if baselineReads > 0 {
      baselineReads -= 1

      return .noValue(.awaitingBaseline)
    }

    return .value(MetricValue(Double(clock.seconds), .percent))
  }

  mutating func close() {
    log.record("close")
  }
}

extension SensorLog {
  var reads: [Int] {
    all.compactMap { $0.hasPrefix("read ") ? Int($0.dropFirst(5)) : nil }
  }

  var isOpen: Bool {
    all.last { $0 == "open" || $0 == "close" } == "open"
  }
}

/// Seeded, so a failing run of the random test can be repeated.
struct SplitMix64: RandomNumberGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15

    var z = state

    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB

    return z ^ (z >> 31)
  }
}

@MainActor
struct MetricsCoordinatorTests {
  let clock = TestClock()
  let logs: [Metric: SensorLog] = Dictionary(uniqueKeysWithValues: Metric.allCases.map { ($0, SensorLog()) })

  func coordinator(
    _ metrics: [Metric] = Metric.allCases,
    configure: (Metric, inout ClockedSensor) -> Void = { _, _ in }
  ) -> MetricsCoordinator<TestClock> {
    let providers = metrics.map { metric in
      var sensor = ClockedSensor(log: logs[metric]!, clock: clock)

      configure(metric, &sensor)

      return (metric, MetricProvider(sensor: sensor))
    }

    return MetricsCoordinator(providers: Dictionary(uniqueKeysWithValues: providers), clock: clock)
  }

  /// Advances one second at a time and waits for every schedule to sleep again between steps,
  /// so no schedule wakes late and drops the ticks it missed.
  func run(until seconds: Int, schedules: Int) async {
    await waitUntil { clock.sleeperCount == schedules }

    while clock.seconds < seconds {
      clock.advance(by: .seconds(1))

      await waitUntil { clock.sleeperCount == schedules }
    }
  }

  @Test func samplesEachMetricOnItsOwnScheduleAtItsDefaultInterval() async {
    let coordinator = coordinator()

    coordinator.start()

    await run(until: 20, schedules: 4)

    #expect(logs[.cpu]!.reads == Array(stride(from: 0, through: 20, by: 2)))
    #expect(logs[.gpu]!.reads == Array(stride(from: 0, through: 20, by: 2)))
    #expect(logs[.temperature]!.reads == [0, 10, 20])
    #expect(logs[.memoryPressure]!.reads == [0, 5, 10, 15, 20])
    #expect(logs[.memory]!.all.isEmpty)
  }

  @Test func sampleThatOnlySetABaselineIsFollowedByTheValueAMomentLater() async {
    let coordinator = coordinator([.cpu, .temperature]) { metric, sensor in
      sensor.baselineReads = metric == .cpu ? 1 : 0
    }

    coordinator.start()

    await waitUntil { clock.sleeperCount == 2 }

    #expect(logs[.cpu]!.reads == [0])
    #expect(coordinator.store[.cpu]?.lastSuccessful == nil)

    clock.advance(by: MetricsCoordinator<TestClock>.baselineSpan)

    await waitUntil { logs[.cpu]!.reads.count == 2 && clock.sleeperCount == 2 }

    #expect(coordinator.store[.cpu]?.lastSuccessful?.value != nil)
    #expect(clock.now.offset == .milliseconds(250))

    await run(until: 6, schedules: 2)

    #expect(logs[.cpu]!.reads == [0, 0, 2, 4, 6])
    #expect(logs[.temperature]!.reads == [0])
  }

  @Test func metricOnlyTheDetailsShowIsSampledOnlyWhileTheyAreVisible() async {
    let coordinator = coordinator()

    coordinator.start()

    await run(until: 9, schedules: 4)

    #expect(logs[.memory]!.all.isEmpty)

    coordinator.areDetailsVisible = true

    await run(until: 20, schedules: 5)

    coordinator.areDetailsVisible = false

    await waitUntil { !logs[.memory]!.isOpen }
    await run(until: 30, schedules: 4)

    #expect(logs[.memory]!.all == ["open", "read 9", "read 14", "read 19", "close"])
  }

  @Test func showingTheDetailsLeavesEveryOtherScheduleAsItIs() async {
    let coordinator = coordinator()

    coordinator.start()

    await run(until: 5, schedules: 4)

    coordinator.areDetailsVisible = true

    await run(until: 13, schedules: 5)

    coordinator.areDetailsVisible = false

    await run(until: 20, schedules: 4)

    #expect(logs[.cpu]!.reads == Array(stride(from: 0, through: 20, by: 2)))
    #expect(logs[.gpu]!.reads == Array(stride(from: 0, through: 20, by: 2)))
    #expect(logs[.temperature]!.reads == [0, 10, 20])
    #expect(logs[.memoryPressure]!.reads == [0, 5, 10, 15, 20])

    for metric in [Metric.cpu, .gpu, .temperature, .memoryPressure] {
      #expect(logs[metric]!.all.filter { !$0.hasPrefix("read") } == ["open"], "\(metric)")
    }
  }

  @Test func visibleDetailsDoNotSampleADisabledMetricOrAStoppedCoordinator() async {
    let coordinator = coordinator([.cpu, .memory])

    coordinator.areDetailsVisible = true

    await run(until: 3, schedules: 0)

    coordinator.start()
    coordinator.disable(.memory)

    await run(until: 6, schedules: 1)

    coordinator.enable(.memory)

    await run(until: 8, schedules: 2)

    #expect(logs[.memory]!.reads == [6])
  }

  @Test func sourceDescribesTheProvidersReadings() {
    let coordinator = coordinator([.gpu])

    #expect(
      coordinator.source(of: .gpu)
        == MetricSource(id: SourceID("test.clocked"), quantity: .utilization, description: "The test clock's seconds"))
  }

  @Test func storeHearsOnceForEverySampleTaken() async {
    let coordinator = coordinator()
    var heard: [Metric: Int] = [:]

    _ = coordinator.store.observe { heard[$0, default: 0] += 1 }

    coordinator.start()

    await run(until: 10, schedules: 4)

    #expect(heard == [.cpu: 6, .gpu: 6, .temperature: 2, .memoryPressure: 3])
    #expect(coordinator.store[.cpu]?.latest?.value == MetricValue(10, .percent))
    #expect(coordinator.store[.cpu]?.history?.count == 6)
  }

  @Test func failingProvidersDoNotHoldUpTheOthers() async {
    let readFailure = SensorError("read failed")

    let coordinator = coordinator { metric, sensor in
      switch metric {
      case .cpu, .memory, .memoryPressure: break
      case .gpu: sensor.failure = readFailure
      case .temperature: sensor.failsToOpen = true
      }
    }

    coordinator.start()

    await run(until: 20, schedules: 4)

    #expect(logs[.cpu]!.reads == Array(stride(from: 0, through: 20, by: 2)))
    #expect(logs[.gpu]!.reads == Array(stride(from: 0, through: 20, by: 2)))
    #expect(coordinator.store[.gpu]?.latest?.state == .unavailable(.sensorFailed(readFailure)))
    #expect(coordinator.store[.gpu]?.history?.count == 11)

    let temperature = coordinator.store[.temperature]?.latest

    #expect(temperature?.state == .unavailable(.sensorFailed(SensorError("cannot open"))))
    #expect(logs[.temperature]!.reads.isEmpty)
  }

  @Test func providerWorkNeverRunsOnTheMainThread() async {
    let log = SensorLog()
    let coordinator = MetricsCoordinator(
      providers: [.cpu: MetricProvider(sensor: ThreadRecordingSensor(log: log))],
      clock: clock
    )

    #expect(pthread_main_np() != 0)

    coordinator.start()

    await run(until: 4, schedules: 1)

    coordinator.stop()

    await waitUntil { log.all.last == "close off main thread" }

    #expect(log.all == ["open", "read", "read", "read", "close"].map { "\($0) off main thread" })
  }

  @Test func lateSampleDropsTheTicksItMissedInsteadOfCatchingUp() async {
    let coordinator = coordinator([.cpu]) { _, sensor in
      sensor.whileReading = [{ [clock] in clock.advance(by: .seconds(7)) }]
    }

    coordinator.start()

    await run(until: 12, schedules: 1)

    #expect(logs[.cpu]!.reads == [0, 8, 10, 12])
  }

  @Test func metricsStartedTogetherKeepTheSameTicksWhenOneProviderOpensSlowly() async {
    let cpuRead = DispatchSemaphore(value: 0)

    let coordinator = coordinator([.cpu, .gpu]) { metric, sensor in
      switch metric {
      case .cpu: sensor.whileReading = [{ cpuRead.signal() }]
      default:
        sensor.whileOpening = [
          { [clock] in
            cpuRead.wait()
            clock.advance(by: .seconds(1))
          }
        ]
      }
    }

    coordinator.start()

    await run(until: 10, schedules: 2)

    #expect(logs[.cpu]!.reads == [0, 2, 4, 6, 8, 10])
    #expect(logs[.gpu]!.reads == [1, 2, 4, 6, 8, 10])
  }

  @Test func changesDuringASampleNeverQueueASecondSample() async {
    let gate = DispatchSemaphore(value: 0)

    let coordinator = coordinator([.cpu]) { _, sensor in
      sensor.whileReading = [{ gate.wait() }]
    }

    coordinator.start()

    await waitUntil { logs[.cpu]!.reads == [0] }

    coordinator.setInterval(.seconds(1), for: .cpu)
    coordinator.disable(.cpu)
    coordinator.enable(.cpu)
    coordinator.setInterval(.seconds(2), for: .cpu)
    gate.signal()

    await waitUntil { clock.sleeperCount == 1 }

    #expect(logs[.cpu]!.all == ["open", "read 0", "close", "open"])

    await run(until: 4, schedules: 1)

    #expect(logs[.cpu]!.reads == [0, 2, 4])
  }

  @Test func disabledMetricHasNoScheduleAndIsNotSampled() async {
    let coordinator = coordinator()

    coordinator.start()

    await run(until: 4, schedules: 4)

    coordinator.disable(.gpu)

    await waitUntil { !logs[.gpu]!.isOpen }
    await run(until: 10, schedules: 3)

    #expect(logs[.gpu]!.reads == [0, 2, 4])
    #expect(logs[.cpu]!.reads == Array(stride(from: 0, through: 10, by: 2)))

    coordinator.enable(.gpu)

    await run(until: 12, schedules: 4)

    #expect(logs[.gpu]!.reads == [0, 2, 4, 10, 12])
    #expect(logs[.gpu]!.all.filter { !$0.hasPrefix("read") } == ["open", "close", "open"])
  }

  @Test func intervalChangeTakesEffectFromTheNextSampleWithoutARestart() async {
    let coordinator = coordinator([.cpu])

    coordinator.start()

    await run(until: 3, schedules: 1)

    coordinator.setInterval(.seconds(5), for: .cpu)

    await run(until: 13, schedules: 1)

    coordinator.setInterval(.seconds(1), for: .cpu)

    await run(until: 15, schedules: 1)

    #expect(logs[.cpu]!.reads == [0, 2, 7, 12, 13, 14, 15])
    #expect(logs[.cpu]!.all.filter { !$0.hasPrefix("read") } == ["open"])
    #expect(coordinator.store[.cpu]?.interval == .seconds(1))
  }

  @Test func stopClosesEveryProviderAndStartResumesWithoutABurst() async {
    let coordinator = coordinator()

    coordinator.start()

    await run(until: 4, schedules: 4)

    coordinator.stop()

    await waitUntil { Metric.allCases.allSatisfy { !logs[$0]!.isOpen } }
    await run(until: 14, schedules: 0)

    coordinator.start()

    await run(until: 16, schedules: 4)

    #expect(logs[.cpu]!.reads == [0, 2, 4, 14, 16])
    #expect(logs[.temperature]!.reads == [0, 14])
    #expect(Metric.allCases.allSatisfy { logs[$0]!.isOpen == !$0.isSampledOnlyForDetails })
  }

  @Test func thousandRandomChangesLeaveExactlyOneScheduleForEachSampledMetric() async {
    let coordinator = coordinator()
    var random = SplitMix64(state: 5)
    var enabled = Set(Metric.allCases)
    var detailsVisible = false
    var intervals = Dictionary(uniqueKeysWithValues: Metric.allCases.map { ($0, $0.defaultInterval) })

    var sampled: Set<Metric> {
      enabled.filter { detailsVisible || !$0.isSampledOnlyForDetails }
    }

    coordinator.start()

    for change in 1...1_000 {
      let metric = Metric.allCases.randomElement(using: &random)!

      switch Int.random(in: 0..<4, using: &random) {
      case 0:
        coordinator.enable(metric)
        enabled.insert(metric)
      case 1:
        coordinator.disable(metric)
        enabled.remove(metric)
      case 2:
        detailsVisible.toggle()
        coordinator.areDetailsVisible = detailsVisible
      default:
        let interval = Duration.seconds(Int.random(in: 1...5, using: &random))

        coordinator.setInterval(interval, for: metric)
        intervals[metric] = interval
      }

      if change.isMultiple(of: 50) {
        await run(until: clock.seconds + 1, schedules: sampled.count)
      }
    }

    await run(until: clock.seconds + 1, schedules: sampled.count)
    await waitUntil { Metric.allCases.allSatisfy { logs[$0]!.isOpen == sampled.contains($0) } }

    let readsBefore = logs.mapValues(\.reads.count)
    let from = clock.seconds

    await run(until: from + 60, schedules: sampled.count)

    for metric in Metric.allCases {
      let reads = logs[metric]!.reads.dropFirst(readsBefore[metric]!)
      let interval = Int(intervals[metric]!.components.seconds)

      if sampled.contains(metric) {
        #expect(reads.count == 60 / interval, "\(metric) every \(interval) s")
        #expect(zip(reads, reads.dropFirst()).allSatisfy { $1 - $0 == interval }, "\(metric) every \(interval) s")
      } else {
        #expect(reads.isEmpty, "\(metric) is not sampled")
      }
    }

    #expect(clock.sleeperCount == sampled.count)
  }
}
