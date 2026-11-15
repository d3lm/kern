import Testing

@testable import KernCore

/// Reports `installed` bytes and replays scripted count reads in order.
struct ScriptedMemoryCounts: MemoryCountSource {
  var installed: UInt64 = 32 << 30
  var reads: [Result<MemoryCounts, SensorError>]

  mutating func open() throws(SensorError) -> UInt64 {
    installed
  }

  mutating func read() throws(SensorError) -> MemoryCounts {
    guard !reads.isEmpty else {
      Issue.record("unexpected read()")
      throw SensorError("unscripted read")
    }

    return try reads.removeFirst().get()
  }

  mutating func close() {}
}

/// Counts in 16 KiB pages, the page size of Apple Silicon, given in GiB.
func memory(anonymous: Double, purgeable: Double = 0, wired: Double = 0, compressor: Double = 0) -> MemoryCounts {
  let pagesPerGiB = Double(1 << 30) / 16_384

  return MemoryCounts(
    pageSize: 16_384,
    anonymousPages: UInt64(anonymous * pagesPerGiB),
    purgeablePages: UInt64(purgeable * pagesPerGiB),
    wiredPages: UInt64(wired * pagesPerGiB),
    compressorPages: UInt64(compressor * pagesPerGiB)
  )
}

struct MemorySensorTests {
  func startedProvider(installed: UInt64 = 32 << 30, _ reads: [Result<MemoryCounts, SensorError>]) async
    -> MetricProvider
  {
    let counts = ScriptedMemoryCounts(installed: installed, reads: reads)
    let provider = MetricProvider(sensor: MemorySensor(counts: counts))

    await provider.start()

    return provider
  }

  @Test func usedMemoryIsAppMemoryPlusWiredPlusCompressedAsAShareOfInstalledMemory() async {
    let provider = await startedProvider([.success(memory(anonymous: 7, purgeable: 1, wired: 6, compressor: 4))])

    let reading = await provider.sample()

    #expect(reading.state == .valid(MetricValue(50, .percent)))
    #expect(reading.source == SourceID("memory.host_statistics64"))
    #expect(reading.quantity == .memoryUsage)
  }

  @Test func firstReadAlreadyHasAValue() async {
    let provider = await startedProvider([.success(memory(anonymous: 8))])

    #expect(await provider.sample().state == .valid(MetricValue(25, .percent)))
  }

  @Test func readingsStayWithinZeroToOneHundredPercent() async {
    let provider = await startedProvider([
      .success(memory(anonymous: 0)),
      .success(memory(anonymous: 20, wired: 8, compressor: 4)),
    ])

    #expect(await provider.sample().state == .valid(MetricValue(0, .percent)))
    #expect(await provider.sample().state == .valid(MetricValue(100, .percent)))
  }

  @Test(arguments: [
    memory(anonymous: 1, purgeable: 2),
    memory(anonymous: 30, wired: 4),
    MemoryCounts(
      pageSize: 16_384, anonymousPages: .max / 2, purgeablePages: 0, wiredPages: 0, compressorPages: 0),
  ])
  func countsThatDoNotFitTogetherFailTheRead(counts: MemoryCounts) async {
    let provider = await startedProvider([.success(counts)])

    let failed = await provider.sample()

    #expect(failed.value == nil)
    #expect(await provider.errorState != nil)
  }

  @Test func failedReadSetsTheErrorStateAndTheNextReadWorks() async {
    let failure = SensorError("host_statistics64 failed")
    let provider = await startedProvider([.failure(failure), .success(memory(anonymous: 16))])

    #expect(await provider.sample().state == .unavailable(.sensorFailed(failure)))
    #expect(await provider.sample().state == .valid(MetricValue(50, .percent)))
    #expect(await provider.errorState == nil)
  }

  @Test func zeroInstalledMemoryFailsToOpen() async {
    let provider = await startedProvider(installed: 0, [])

    #expect(await provider.availability == .unavailable(SensorError("the installed memory reads as 0 bytes")))
  }

  @Test func liveSensorGivesAReadingWithinRange() throws {
    var sensor = MemorySensor()

    try sensor.open()

    defer { sensor.close() }

    guard case .value(let reading) = try sensor.read() else {
      Issue.record("expected a value")
      return
    }

    #expect(reading.unit == .percent)
    #expect(reading.value > 0 && reading.value < 100)
  }
}
