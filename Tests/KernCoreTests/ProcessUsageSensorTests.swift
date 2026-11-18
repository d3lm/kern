import Darwin
import Testing

@testable import KernCore

struct ScriptedCounters: ProcessCounterSource {
  var reads: [Result<ProcessCounters, SensorError>]

  mutating func read() throws(SensorError) -> ProcessCounters {
    guard !reads.isEmpty else {
      Issue.record("unexpected read()")
      throw SensorError("unscripted read")
    }

    return try reads.removeFirst().get()
  }
}

func counters(cpu: Duration, at uptime: Duration, footprint: UInt64 = 20 << 20) -> ProcessCounters {
  ProcessCounters(cpuTime: cpu, uptime: uptime, footprintBytes: footprint)
}

struct ProcessUsageSensorTests {
  func startedProvider(_ reads: [Result<ProcessCounters, SensorError>]) async -> MetricProvider {
    let provider = MetricProvider(sensor: ProcessUsageSensor(counters: ScriptedCounters(reads: reads)))

    await provider.start()

    return provider
  }

  func startedProvider(_ reads: [ProcessCounters]) async -> MetricProvider {
    await startedProvider(reads.map { .success($0) })
  }

  @Test func firstSampleAfterStartIsUnavailableWithoutAnError() async {
    let provider = await startedProvider([counters(cpu: .seconds(3), at: .seconds(100))])

    let first = await provider.sample()

    #expect(first.state == .unavailable(.noValue(.awaitingBaseline)))
    #expect(await provider.errorState == nil)
  }

  @Test func usageIsTheCPUTimeUsedAsAShareOfTheTimeThatPassedWithTheLatestFootprint() async {
    let provider = await startedProvider([
      counters(cpu: .seconds(3), at: .seconds(100), footprint: 10 << 20),
      counters(cpu: .seconds(3) + .milliseconds(125), at: .seconds(102), footprint: 18 << 20),
    ])

    _ = await provider.sample()

    let reading = await provider.sample()

    #expect(reading.value == MetricValue(6.25, .percent, footprintBytes: 18 << 20))
    #expect(reading.source == SourceID("kern.getrusage_task_info"))
    #expect(reading.quantity == .processUsage)
  }

  @Test func usageOfMoreThanOneBusyThreadExceedsOneHundredPercent() async {
    let provider = await startedProvider([
      counters(cpu: .zero, at: .seconds(10)), counters(cpu: .seconds(3), at: .seconds(12)),
    ])

    _ = await provider.sample()

    #expect(await provider.sample().value?.value == 150)
  }

  @Test func noTimePassingIsUnavailableWithoutAnError() async {
    let provider = await startedProvider([
      counters(cpu: .zero, at: .seconds(10)), counters(cpu: .zero, at: .seconds(10)),
    ])

    _ = await provider.sample()

    let unchanged = await provider.sample()

    #expect(unchanged.state == .unavailable(.noValue(.countersUnchanged)))
    #expect(await provider.errorState == nil)
  }

  @Test(arguments: [counters(cpu: .seconds(1), at: .seconds(12)), counters(cpu: .seconds(3), at: .seconds(8))])
  func countersThatGoBackwardsAreUnavailableAndBecomeTheNewBaseline(backwards: ProcessCounters) async {
    let provider = await startedProvider([
      counters(cpu: .seconds(2), at: .seconds(10)),
      backwards,
      counters(cpu: backwards.cpuTime + .seconds(1), at: backwards.uptime + .seconds(4)),
    ])

    _ = await provider.sample()

    #expect(await provider.sample().state == .unavailable(.noValue(.countersWentBackwards)))
    #expect(await provider.sample().value?.value == 25)
  }

  @Test func failedReadSetsTheErrorStateAndTheNextReadWorks() async {
    let failure = SensorError("getrusage failed")

    let provider = await startedProvider([
      .success(counters(cpu: .zero, at: .seconds(10))),
      .failure(failure),
      .success(counters(cpu: .milliseconds(20), at: .seconds(12))),
    ])

    _ = await provider.sample()

    #expect(await provider.sample().state == .unavailable(.sensorFailed(failure)))
    #expect(await provider.sample().value?.value == 1)
    #expect(await provider.errorState == nil)
  }

  @Test func restartDiscardsTheBaselineFromBeforeStop() async {
    let provider = await startedProvider([
      counters(cpu: .zero, at: .seconds(10)), counters(cpu: .seconds(1), at: .seconds(12)),
    ])

    _ = await provider.sample()

    await provider.stop()
    await provider.start()

    #expect(await provider.sample().state == .unavailable(.noValue(.awaitingBaseline)))
  }

  /// Keeps one thread busy for 300 ms between the reads, which must read at least half of one logical CPU and can read
  /// more while other tests run in the same process, but never more than every logical CPU.
  @Test func liveSensorReadsABusyThreadAsAboutOneLogicalCPUAndTheFootprintActivityMonitorShows() throws {
    var sensor = ProcessUsageSensor()

    try sensor.open()

    defer { sensor.close() }

    #expect(try sensor.read() == .noValue(.awaitingBaseline))

    let start = ContinuousClock.now

    var spin: UInt64 = 1

    while ContinuousClock.now - start < .milliseconds(300) {
      spin = spin &* 6_364_136_223_846_793_005 &+ 1
    }

    guard case .value(let reading) = try sensor.read() else {
      Issue.record("expected a value from the second read")
      return
    }

    var usage = rusage_info_v4()

    let result = withUnsafeMutablePointer(to: &usage) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }

    let footprint = try #require(reading.footprintBytes)

    #expect(spin != 0)
    #expect(reading.unit == .percent)
    #expect((50...Double(sysconf(_SC_NPROCESSORS_ONLN)) * 100).contains(reading.value))
    #expect(result == 0)
    #expect(abs(Double(footprint) - Double(usage.ri_phys_footprint)) < Double(4 << 20))
  }
}
