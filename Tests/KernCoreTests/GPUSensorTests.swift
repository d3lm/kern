import Testing

@testable import KernCore

/// Replays scripted counter reads in order.
struct ScriptedResidency: GPUStateResidencySource {
  var reads: [Result<[String: UInt64], SensorError>]

  mutating func open() throws(SensorError) {}

  mutating func read() throws(SensorError) -> [String: UInt64] {
    guard !reads.isEmpty else {
      Issue.record("unexpected read()")
      throw SensorError("unscripted read")
    }

    return try reads.removeFirst().get()
  }

  mutating func close() {}
}

/// Counters for the `OFF` state followed by `P1`, `P2`, … in order.
func gpu(off: UInt64, _ performanceStates: UInt64...) -> [String: UInt64] {
  var residency = ["OFF": off]

  for (index, ticks) in performanceStates.enumerated() {
    residency["P\(index + 1)"] = ticks
  }

  return residency
}

struct GPUSensorTests {
  let failure = SensorError("IOReport samples have no GPUPH channel")

  func startedProvider(_ reads: [Result<[String: UInt64], SensorError>]) async -> MetricProvider {
    let provider = MetricProvider(sensor: GPUSensor(residency: ScriptedResidency(reads: reads)))

    await provider.start()

    return provider
  }

  func startedProvider(_ reads: [[String: UInt64]]) async -> MetricProvider {
    await startedProvider(reads.map { .success($0) })
  }

  @Test func firstSampleAfterStartIsUnavailableWithoutAnError() async {
    let provider = await startedProvider([gpu(off: 500, 500)])

    let first = await provider.sample()

    #expect(first.state == .unavailable(.noValue(.awaitingBaseline)))
    #expect(first.value == nil)
    #expect(await provider.errorState == nil)
    #expect(await provider.availability == .available)
  }

  @Test func readingIsTheShareOfTimeOutsideTheOffState() async {
    let provider = await startedProvider([
      gpu(off: 1_000, 500, 0, 0),
      gpu(off: 1_600, 800, 0, 100),
    ])

    _ = await provider.sample()

    let reading = await provider.sample()

    #expect(reading.state == .valid(MetricValue(40, .percent)))
    #expect(reading.source == SourceID("gpu.ioreport.gpuph"))
  }

  @Test func everySampleSaysItIsActiveResidencyNotUtilization() async {
    let provider = await startedProvider([gpu(off: 0, 0), gpu(off: 10, 10)])

    let baseline = await provider.sample()
    let reading = await provider.sample()

    #expect(baseline.quantity == .activeResidency)
    #expect(reading.quantity == .activeResidency)
    #expect(provider.quantity == .activeResidency)
  }

  @Test func readingsStayWithinZeroToOneHundredPercent() async {
    let max = UInt64.max

    let provider = await startedProvider([
      gpu(off: 0, 0, 0),
      gpu(off: 200, 0, 0),
      gpu(off: 200, 100, 100),
      gpu(off: max, max, max),
    ])

    _ = await provider.sample()

    let allOff = await provider.sample()
    let allActive = await provider.sample()
    let largestPossibleStep = await provider.sample()

    #expect(allOff.state == .valid(MetricValue(0, .percent)))
    #expect(allActive.state == .valid(MetricValue(100, .percent)))
    #expect(largestPossibleStep.value.map { (0...100).contains($0.value) } == true)
  }

  @Test func unchangedCountersAreUnavailableWithoutAnError() async {
    let residency = gpu(off: 700, 300)
    let provider = await startedProvider([residency, residency])

    _ = await provider.sample()

    let unchanged = await provider.sample()

    #expect(unchanged.state == .unavailable(.noValue(.countersUnchanged)))
    #expect(await provider.errorState == nil)
    #expect(await provider.lastSuccessfulSample == nil)
  }

  @Test func countersThatGoBackwardsAreUnavailableAndBecomeTheNewBaseline() async {
    let provider = await startedProvider([
      gpu(off: 500, 500),
      gpu(off: 700, 400),
      gpu(off: 800, 500),
    ])

    _ = await provider.sample()

    let backwards = await provider.sample()
    let next = await provider.sample()

    #expect(backwards.state == .unavailable(.noValue(.countersWentBackwards)))
    #expect(next.state == .valid(MetricValue(50, .percent)))
  }

  @Test func changeInThePowerStatesStartsANewBaseline() async {
    let provider = await startedProvider([
      gpu(off: 100, 100),
      gpu(off: 100, 100, 100),
      gpu(off: 100, 100, 200),
    ])

    _ = await provider.sample()

    let afterChange = await provider.sample()
    let next = await provider.sample()

    #expect(afterChange.state == .unavailable(.noValue(.awaitingBaseline)))
    #expect(next.state == .valid(MetricValue(100, .percent)))
  }

  @Test func powerStatesWithoutAnOffStateFailTheRead() async {
    let provider = await startedProvider([["P1": 100, "P2": 100]])

    let sample = await provider.sample()

    guard case .unavailable(.sensorFailed(let error)) = sample.state else {
      Issue.record("expected a failed read, got \(sample.state)")
      return
    }

    #expect(await provider.errorState == error)
  }

  /// A state Kern does not know might be an inactive one, and counting it as active would inflate the reading.
  @Test(arguments: ["DOWN", "IDLE", "P", "P1a", "p1"])
  func unfamiliarPowerStateFailsTheRead(state: String) async {
    var residency = gpu(off: 100, 100)

    residency[state] = 100

    let provider = await startedProvider([residency])

    let sample = await provider.sample()

    guard case .unavailable(.sensorFailed(let error)) = sample.state else {
      Issue.record("expected a failed read, got \(sample.state)")
      return
    }

    #expect(error.description.contains(state))
  }

  @Test func failedReadKeepsTheBaselineAndTheNextReadCoversTheWholeInterval() async {
    let provider = await startedProvider([
      .success(gpu(off: 0, 0)),
      .failure(failure),
      .success(["P1": 50]),
      .success(gpu(off: 75, 25)),
    ])

    _ = await provider.sample()

    let failed = await provider.sample()
    let badShape = await provider.sample()
    let recovered = await provider.sample()

    #expect(failed.state == .unavailable(.sensorFailed(failure)))
    #expect(badShape.value == nil)
    #expect(recovered.state == .valid(MetricValue(25, .percent)))
    #expect(await provider.errorState == nil)
  }

  @Test func restartDiscardsTheBaselineFromBeforeStop() async {
    let provider = await startedProvider([
      gpu(off: 100, 0),
      gpu(off: 100, 100),
    ])

    _ = await provider.sample()

    await provider.stop()
    await provider.start()

    #expect(await provider.sample().state == .unavailable(.noValue(.awaitingBaseline)))
  }

  @Test func ioReportReportsAnOffStateAndPerformanceStates() throws {
    var source = IOReportGPUStateResidency()

    try source.open()

    defer { source.close() }

    let residency = try source.read()

    #expect(residency["OFF"] != nil)
    #expect(residency.count > 1)
  }

  @Test func liveSensorGivesAReadingWithinRange() async throws {
    var sensor = GPUSensor()

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
