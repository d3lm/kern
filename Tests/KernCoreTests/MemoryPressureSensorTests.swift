import Darwin
import Synchronization
import Testing

@testable import KernCore

final class ScriptedAvailability: MemoryAvailabilitySource, Sendable {
  private let results: Mutex<[Result<Int, SensorError>]>

  init(_ results: [Result<Int, SensorError>]) {
    self.results = Mutex(results)
  }

  func availablePercent() throws(SensorError) -> Int {
    let next = results.withLock { $0.isEmpty ? nil : $0.removeFirst() }

    guard let next else {
      Issue.record("unexpected read")
      throw SensorError("unscripted read")
    }

    return try next.get()
  }
}

struct MemoryPressureSensorTests {
  func startedProvider(_ results: [Result<Int, SensorError>]) async -> MetricProvider {
    let provider = MetricProvider(sensor: MemoryPressureSensor(availability: ScriptedAvailability(results)))

    await provider.start()

    return provider
  }

  @Test func pressureIsTheShareOfMemoryThatIsNotAvailable() async {
    let provider = await startedProvider([.success(50), .success(30)])

    let reading = await provider.sample()

    #expect(reading.state == .valid(MetricValue(70, .percent)))
    #expect(reading.source == SourceID("memory.memorystatus_level"))
    #expect(reading.quantity == .memoryPressure)
  }

  @Test func pressureSpansZeroToOneHundredPercent() async {
    let provider = await startedProvider([.success(50), .success(100), .success(0)])

    #expect(await provider.sample().state == .valid(MetricValue(0, .percent)))
    #expect(await provider.sample().state == .valid(MetricValue(100, .percent)))
  }

  @Test(arguments: [-1, 101])
  func shareOutsideZeroToOneHundredFailsTheRead(percent: Int) async {
    let provider = await startedProvider([.success(50), .success(percent)])

    let failed = await provider.sample()

    #expect(failed.value == nil)
    #expect(await provider.errorState != nil)
  }

  @Test func counterThatCannotBeReadMakesTheSensorUnavailableFromTheStart() async {
    let failure = SensorError("sysctl kern.memorystatus_level failed")
    let provider = await startedProvider([.failure(failure)])

    #expect(await provider.availability == .unavailable(failure))
  }

  @Test func failedReadSetsTheErrorStateAndTheNextReadWorks() async {
    let failure = SensorError("sysctl kern.memorystatus_level failed")
    let provider = await startedProvider([.success(50), .failure(failure), .success(40)])

    #expect(await provider.sample().state == .unavailable(.sensorFailed(failure)))
    #expect(await provider.sample().state == .valid(MetricValue(60, .percent)))
    #expect(await provider.errorState == nil)
  }

  @Test func liveSensorAgreesWithTheSystemCounter() throws {
    var sensor = MemoryPressureSensor()

    try sensor.open()

    guard case .value(let reading) = try sensor.read() else {
      Issue.record("expected a value")
      return
    }

    var level: Int32 = 0
    var size = MemoryLayout<Int32>.size

    #expect(sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0)
    #expect(abs(reading.value - Double(100 - level)) <= 2)
  }
}
