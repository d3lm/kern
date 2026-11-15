import Darwin
import KernCore
import Synchronization
import Testing

final class SensorLog: Sendable {
  private let events = Mutex<[String]>([])

  func record(_ event: String) {
    events.withLock { $0.append(event) }
  }

  var all: [String] { events.withLock { $0 } }
}

/// Replays scripted results in order. Running out of script means the provider made a call
/// the test did not expect.
struct ScriptedSensor: MetricSensor {
  let source = SourceID("test.sensor")
  let log: SensorLog
  var openResults: [Result<Void, SensorError>] = [.success(())]
  var readResults: [Result<SensorReading, SensorError>] = []

  mutating func open() throws(SensorError) {
    log.record("open")

    guard !openResults.isEmpty else {
      Issue.record("unexpected open()")
      throw SensorError("unscripted open")
    }

    try openResults.removeFirst().get()
  }

  mutating func read() throws(SensorError) -> SensorReading {
    log.record("read")

    guard !readResults.isEmpty else {
      Issue.record("unexpected read()")
      throw SensorError("unscripted read")
    }

    return try readResults.removeFirst().get()
  }

  mutating func close() {
    log.record("close")
  }
}

struct ThreadRecordingSensor: MetricSensor {
  let source = SourceID("test.thread")
  let log: SensorLog

  private func record(_ call: String) {
    log.record("\(call) \(pthread_main_np() != 0 ? "on" : "off") main thread")
  }

  mutating func open() throws(SensorError) {
    record("open")
  }

  mutating func read() throws(SensorError) -> SensorReading {
    record("read")
    return .value(MetricValue(1, .percent))
  }

  mutating func close() {
    record("close")
  }
}

struct MetricProviderTests {
  let log = SensorLog()
  let failure = SensorError("counter unavailable")

  @Test func sampleBeforeStartIsUnavailableAndLeavesTheSensorAlone() async {
    let provider = MetricProvider(sensor: ScriptedSensor(log: log))

    let sample = await provider.sample()

    #expect(sample.state == .unavailable(.notStarted))
    #expect(sample.value == nil)
    #expect(await provider.availability == .stopped)
    #expect(log.all.isEmpty)
  }

  @Test func validReadingCarriesValueUnitSourceAndAcquisitionTime() async {
    let provider = MetricProvider(
      sensor: ScriptedSensor(log: log, readResults: [.success(.value(MetricValue(42, .percent)))]))

    await provider.start()

    let before = ContinuousClock.now
    let sample = await provider.sample()
    let after = ContinuousClock.now

    #expect(sample.state == .valid(MetricValue(42, .percent)))
    #expect(sample.source == SourceID("test.sensor"))
    #expect(before <= sample.acquiredAt && sample.acquiredAt <= after)
    #expect(await provider.lastSuccessfulSample == sample)
    #expect(await provider.availability == .available)
    #expect(await provider.errorState == nil)
  }

  @Test func failedReadIsUnavailableWithoutANumberAndKeepsTheLastSuccess() async {
    let provider = MetricProvider(
      sensor: ScriptedSensor(
        log: log,
        readResults: [.success(.value(MetricValue(10, .percent))), .failure(failure)]
      ))

    await provider.start()

    let good = await provider.sample()
    let failed = await provider.sample()

    #expect(failed.state == .unavailable(.sensorFailed(failure)))
    #expect(failed.value == nil)
    #expect(await provider.errorState == failure)
    #expect(await provider.availability == .unavailable(failure))
    #expect(await provider.lastSuccessfulSample == good)
  }

  @Test func nextSuccessfulReadClearsTheError() async {
    let provider = MetricProvider(
      sensor: ScriptedSensor(
        log: log,
        readResults: [.failure(failure), .success(.value(MetricValue(55, .celsius)))]
      ))

    await provider.start()

    _ = await provider.sample()

    let recovered = await provider.sample()

    #expect(recovered.state == .valid(MetricValue(55, .celsius)))
    #expect(await provider.errorState == nil)
    #expect(await provider.availability == .available)
    #expect(await provider.lastSuccessfulSample == recovered)
  }

  @Test func readingWithNoValueIsUnavailableButClearsTheError() async {
    let provider = MetricProvider(
      sensor: ScriptedSensor(
        log: log,
        readResults: [.failure(failure), .success(.noValue(.awaitingBaseline))]
      ))

    await provider.start()

    _ = await provider.sample()

    let noValue = await provider.sample()

    #expect(noValue.state == .unavailable(.noValue(.awaitingBaseline)))
    #expect(noValue.value == nil)
    #expect(await provider.errorState == nil)
    #expect(await provider.availability == .available)
    #expect(await provider.lastSuccessfulSample == nil)
  }

  @MainActor @Test func sensorWorkRunsOffTheMainThread() async {
    let provider = MetricProvider(sensor: ThreadRecordingSensor(log: log))
    #expect(pthread_main_np() != 0)

    await provider.start()

    _ = await provider.sample()

    await provider.stop()

    #expect(log.all == ["open off main thread", "read off main thread", "close off main thread"])
  }

  @Test func failedOpenMakesTheProviderUnavailableUntilStartSucceeds() async {
    let provider = MetricProvider(
      sensor: ScriptedSensor(
        log: log,
        openResults: [.failure(failure), .success(())],
        readResults: [.success(.value(MetricValue(3, .percent)))]
      ))

    await provider.start()

    let whileClosed = await provider.sample()

    #expect(await provider.availability == .unavailable(failure))
    #expect(whileClosed.state == .unavailable(.sensorFailed(failure)))
    #expect(log.all == ["open"])

    await provider.start()

    let afterRetry = await provider.sample()

    #expect(afterRetry.state == .valid(MetricValue(3, .percent)))
    #expect(log.all == ["open", "open", "read"])
  }

  @Test func startAndStopEachTouchTheSensorOnlyOnce() async {
    let provider = MetricProvider(sensor: ScriptedSensor(log: log))

    await provider.start()
    await provider.start()
    await provider.stop()
    await provider.stop()

    let afterStop = await provider.sample()

    #expect(afterStop.state == .unavailable(.notStarted))
    #expect(await provider.availability == .stopped)
    #expect(log.all == ["open", "close"])
  }
}
