import Darwin
import Testing

@testable import KernCore

struct ScriptedTicks: CPUTickSource {
  var coreKinds: [CoreKind]?
  var reads: [Result<[CPUTicks], SensorError>]

  mutating func open() throws(SensorError) {}

  mutating func read() throws(SensorError) -> [CPUTicks] {
    guard !reads.isEmpty else {
      Issue.record("unexpected read()")
      throw SensorError("unscripted read")
    }

    return try reads.removeFirst().get()
  }

  mutating func close() {}
}

func cpu(user: UInt32 = 0, system: UInt32 = 0, idle: UInt32 = 0, nice: UInt32 = 0) -> CPUTicks {
  CPUTicks(user: user, system: system, idle: idle, nice: nice)
}

struct CPUSensorTests {
  let failure = SensorError("host_processor_info failed")

  func startedProvider(kinds: [CoreKind]? = nil, _ reads: [Result<[CPUTicks], SensorError>]) async -> MetricProvider {
    let provider = MetricProvider(sensor: CPUSensor(ticks: ScriptedTicks(coreKinds: kinds, reads: reads)))

    await provider.start()

    return provider
  }

  func startedProvider(kinds: [CoreKind]? = nil, _ reads: [[CPUTicks]]) async -> MetricProvider {
    await startedProvider(kinds: kinds, reads.map { .success($0) })
  }

  func secondValue(kinds: [CoreKind]?, _ reads: [[CPUTicks]]) async -> MetricValue? {
    let provider = await startedProvider(kinds: kinds, reads)

    _ = await provider.sample()

    return await provider.sample().value
  }

  @Test func eachCoreHasItsOwnShareGroupedByKindInLogicalCPUOrder() async {
    let kinds: [CoreKind] = [.efficiency, .efficiency, .performance, .performance, .performance]

    let later = [
      cpu(user: 90, idle: 10), cpu(user: 80, idle: 20), cpu(user: 10, idle: 90), cpu(idle: 100),
      cpu(user: 60, idle: 40),
    ]

    let value = await secondValue(kinds: kinds, [Array(repeating: cpu(), count: 5), later])

    #expect(value?.cores == CoreUtilization(performance: [10, 0, 60], efficiency: [90, 80]))
  }

  @Test func totalIsTheMeanOfTheCoresOfTheSameSample() async throws {
    let value = await secondValue(
      kinds: [.efficiency, .efficiency, .performance, .performance],
      [
        Array(repeating: cpu(idle: 0), count: 4),
        [cpu(user: 150, idle: 50), cpu(system: 37, idle: 163), cpu(idle: 197, nice: 3), cpu(user: 200)],
      ])

    let total = try #require(value?.value)
    let cores = try #require(value?.cores)
    let shares = cores.performance + cores.efficiency

    #expect(abs(total - shares.reduce(0, +) / Double(shares.count)) < 1e-9)
    #expect(abs(total - 48.75) < 1e-9)
  }

  @Test(arguments: [nil, [CoreKind.performance], [.performance, .efficiency, .efficiency]])
  func coresWhoseKindsAreNotKnownForEveryCPUHaveNoSharesButTheTotalStays(kinds: [CoreKind]?) async {
    let value = await secondValue(kinds: kinds, [[cpu(), cpu()], [cpu(user: 50, idle: 50), cpu(idle: 100)]])

    #expect(value == MetricValue(25, .percent, split: CPUTimeSplit(user: 25, system: 0)))
  }

  @Test func coreWhoseCountersDidNotAdvanceLeavesNoSharesButTheTotalStays() async {
    let value = await secondValue(
      kinds: [.performance, .efficiency], [[cpu(), cpu(idle: 10)], [cpu(user: 50, idle: 50), cpu(idle: 10)]])

    #expect(value == MetricValue(50, .percent, split: CPUTimeSplit(user: 50, system: 0)))
  }

  @Test func busyTimeSplitsIntoUserAndSystemTimeThatAddUpToTheTotal() async throws {
    let value = await secondValue(
      kinds: nil,
      [
        [cpu(user: 10, system: 20, idle: 30, nice: 40), cpu(user: 5, system: 5, idle: 5, nice: 5)],
        [cpu(user: 40, system: 40, idle: 70, nice: 50), cpu(user: 5, system: 65, idle: 45, nice: 5)],
      ])

    let total = try #require(value?.value)
    let split = try #require(value?.split)

    #expect(split == CPUTimeSplit(user: 20, system: 40))
    #expect(abs(split.user + split.system - total) < 1e-9)
  }

  @Test func firstSampleAfterStartIsUnavailableWithoutAnError() async {
    let provider = await startedProvider([[cpu(user: 500, idle: 500)]])

    let first = await provider.sample()

    #expect(first.state == .unavailable(.noValue(.awaitingBaseline)))
    #expect(first.value == nil)
    #expect(await provider.errorState == nil)
    #expect(await provider.availability == .available)
    #expect(await provider.lastSuccessfulSample == nil)
  }

  @Test func busyProcessesRaiseTheReadingByTheirShareOfAllLogicalCPUs() async {
    let idle = Array(repeating: cpu(idle: 1_000), count: 10)

    let fourBusy =
      Array(repeating: cpu(user: 200, idle: 1_000), count: 4) + Array(repeating: cpu(idle: 1_200), count: 6)

    let provider = await startedProvider([idle, fourBusy])

    _ = await provider.sample()

    let reading = await provider.sample()

    #expect(reading.value?.value == 40)
    #expect(reading.source == SourceID("cpu.host_processor_info"))
    #expect(reading.quantity == .utilization)
  }

  @Test func userSystemAndNiceTimeCountAsBusy() async {
    let provider = await startedProvider([
      [cpu(user: 100, system: 100, idle: 100, nice: 100)],
      [cpu(user: 110, system: 120, idle: 140, nice: 130)],
    ])

    _ = await provider.sample()

    #expect(await provider.sample().value?.value == 60)
  }

  @Test func readingsStayWithinZeroToOneHundredPercent() async {
    let max = UInt32.max

    let provider = await startedProvider([
      [cpu(), cpu()],
      [cpu(idle: 200), cpu(idle: 200)],
      [cpu(user: 100, idle: 200), cpu(system: 100, idle: 200)],
      [cpu(user: max, system: max, idle: max, nice: max), cpu(user: max, system: max, idle: max, nice: max)],
    ])

    _ = await provider.sample()

    let allIdle = await provider.sample()
    let allBusy = await provider.sample()
    let largestPossibleStep = await provider.sample()

    #expect(allIdle.value?.value == 0)
    #expect(allBusy.value?.value == 100)
    #expect(largestPossibleStep.value.map { (0...100).contains($0.value) } == true)
  }

  @Test func unchangedCountersAreUnavailableWithoutAnError() async {
    let ticks = [cpu(user: 300, idle: 700), cpu(user: 50, idle: 950)]
    let provider = await startedProvider([ticks, ticks])

    _ = await provider.sample()

    let unchanged = await provider.sample()

    #expect(unchanged.state == .unavailable(.noValue(.countersUnchanged)))
    #expect(unchanged.value == nil)
    #expect(await provider.errorState == nil)
    #expect(await provider.lastSuccessfulSample == nil)
  }

  @Test func countersThatGoBackwardsAreUnavailableAndBecomeTheNewBaseline() async {
    let provider = await startedProvider([
      [cpu(user: 500, idle: 500), cpu(idle: 1_000)],
      [cpu(user: 400, idle: 700), cpu(idle: 1_200)],
      [cpu(user: 600, idle: 700), cpu(idle: 1_400)],
    ])

    _ = await provider.sample()

    let backwards = await provider.sample()
    let next = await provider.sample()

    #expect(backwards.state == .unavailable(.noValue(.countersWentBackwards)))
    #expect(await provider.lastSuccessfulSample == next)
    #expect(next.value?.value == 50)
  }

  @Test func failedReadSetsTheErrorStateAndTheNextReadWorks() async {
    let provider = await startedProvider([
      .success([cpu(user: 0, idle: 0)]),
      .failure(failure),
      .success([cpu(user: 25, idle: 75)]),
    ])

    _ = await provider.sample()

    let failed = await provider.sample()

    #expect(failed.state == .unavailable(.sensorFailed(failure)))
    #expect(await provider.errorState == failure)

    let recovered = await provider.sample()

    #expect(recovered.value?.value == 25)
    #expect(await provider.errorState == nil)
    #expect(await provider.availability == .available)
  }

  @Test func changeInLogicalCPUCountStartsANewBaseline() async {
    let provider = await startedProvider([
      [cpu(idle: 100), cpu(idle: 100)],
      [cpu(user: 100, idle: 100)],
      [cpu(user: 200, idle: 100)],
    ])

    _ = await provider.sample()

    let afterChange = await provider.sample()
    let next = await provider.sample()

    #expect(afterChange.state == .unavailable(.noValue(.awaitingBaseline)))
    #expect(next.value?.value == 100)
  }

  @Test func restartDiscardsTheBaselineFromBeforeStop() async {
    let provider = await startedProvider([
      [cpu(idle: 100)],
      [cpu(user: 100, idle: 100)],
    ])

    _ = await provider.sample()

    await provider.stop()
    await provider.start()

    #expect(await provider.sample().state == .unavailable(.noValue(.awaitingBaseline)))
  }

  @Test func machCountersCoverEveryLogicalCPU() throws {
    var source = MachProcessorTicks()

    _ = try source.open()

    defer { source.close() }

    let ticks = try source.read()

    #expect(ticks.count == sysconf(_SC_NPROCESSORS_CONF))
  }

  @Test(.enabled(if: onAppleSiliconHardware)) func deviceTreeNamesTheKindOfEveryLogicalCPU() throws {
    func logicalCPUs(_ level: Int) -> Int {
      var count: Int32 = 0
      var size = MemoryLayout<Int32>.size

      return sysctlbyname("hw.perflevel\(level).logicalcpu", &count, &size, nil, 0) == 0 ? Int(count) : 0
    }

    let kinds = try #require(MachProcessorTicks.deviceTreeCoreKinds())

    #expect(kinds.count == sysconf(_SC_NPROCESSORS_CONF))
    #expect(kinds.count { $0 == .performance } == logicalCPUs(0))
    #expect(kinds.count { $0 == .efficiency } == logicalCPUs(1))
  }

  @Test @MainActor func coreKindsAreKnownBeforeTheFirstRead() {
    let kinds: [CoreKind] = [.efficiency, .performance]

    let coordinator = MetricsCoordinator(
      providers: [.cpu: MetricProvider(sensor: CPUSensor(ticks: ScriptedTicks(coreKinds: kinds, reads: [])))])

    #expect(CPUSensor().coreKinds == MachProcessorTicks.deviceTreeCoreKinds())
    #expect(coordinator.source(of: .cpu).coreKinds == kinds)
  }

  @Test func liveSensorGivesAReadingWithinRange() async throws {
    var sensor = CPUSensor()

    try sensor.open()

    defer { sensor.close() }

    #expect(try sensor.read() == .noValue(.awaitingBaseline))

    try await Task.sleep(for: .milliseconds(200))

    guard case .value(let reading) = try sensor.read() else {
      Issue.record("expected a value from the second read")
      return
    }

    #expect(reading.unit == .percent)
    #expect((0...100).contains(reading.value))

    if onAppleSiliconHardware {
      let cores = try #require(reading.cores)
      let shares = cores.performance + cores.efficiency

      #expect(shares.count == sysconf(_SC_NPROCESSORS_CONF))
      #expect(shares.allSatisfy { (0...100).contains($0) })
    }
  }
}
