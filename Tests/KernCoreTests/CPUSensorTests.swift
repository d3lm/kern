import Darwin
import Testing

@testable import KernCore

/// Replays scripted counter reads in order.
struct ScriptedTicks: CPUTickSource {
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

  func startedProvider(_ reads: [Result<[CPUTicks], SensorError>]) async -> MetricProvider {
    let provider = MetricProvider(sensor: CPUSensor(ticks: ScriptedTicks(reads: reads)))

    await provider.start()

    return provider
  }

  func startedProvider(_ reads: [[CPUTicks]]) async -> MetricProvider {
    await startedProvider(reads.map { .success($0) })
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

    #expect(reading.state == .valid(MetricValue(40, .percent)))
    #expect(reading.source == SourceID("cpu.host_processor_info"))
    #expect(reading.quantity == .utilization)
  }

  @Test func userSystemAndNiceTimeCountAsBusy() async {
    let provider = await startedProvider([
      [cpu(user: 100, system: 100, idle: 100, nice: 100)],
      [cpu(user: 110, system: 120, idle: 140, nice: 130)],
    ])

    _ = await provider.sample()

    #expect(await provider.sample().state == .valid(MetricValue(60, .percent)))
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

    #expect(allIdle.state == .valid(MetricValue(0, .percent)))
    #expect(allBusy.state == .valid(MetricValue(100, .percent)))
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
    #expect(next.state == .valid(MetricValue(50, .percent)))
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

    #expect(recovered.state == .valid(MetricValue(25, .percent)))
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
    #expect(next.state == .valid(MetricValue(100, .percent)))
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

    try source.open()

    defer { source.close() }

    let ticks = try source.read()

    #expect(ticks.count == sysconf(_SC_NPROCESSORS_CONF))
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
  }
}
