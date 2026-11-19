import Darwin
import Testing

@testable import KernCore

struct ScriptedCapacity: VolumeCapacitySource {
  var reads: [Result<VolumeCapacity, SensorError>]

  mutating func read() throws(SensorError) -> VolumeCapacity {
    guard !reads.isEmpty else {
      Issue.record("unexpected read()")
      throw SensorError("unscripted read")
    }

    return try reads.removeFirst().get()
  }
}

func capacity(total: Int64, available: Int64) -> Result<VolumeCapacity, SensorError> {
  .success(VolumeCapacity(totalBytes: total, availableBytes: available))
}

struct StorageSensorTests {
  func startedProvider(_ reads: [Result<VolumeCapacity, SensorError>]) async -> MetricProvider {
    let provider = MetricProvider(sensor: StorageSensor(capacity: ScriptedCapacity(reads: reads)))

    await provider.start()

    return provider
  }

  @Test func usageIsTheShareOfTheCapacityThatIsNotAvailableFromTheFirstRead() async {
    let provider = await startedProvider([capacity(total: 1_000, available: 115)])

    let reading = await provider.sample()

    #expect(reading.value == MetricValue(88.5, .percent))
    #expect(reading.source == SourceID("storage.volume_capacity"))
    #expect(reading.quantity == .storageUsage)
  }

  @Test(arguments: [(Int64(0), 100.0), (500, 50), (1_000, 0)])
  func fullAndEmptyDisksAreTheEndsOfTheRange(available: Int64, percent: Double) async {
    let provider = await startedProvider([capacity(total: 1_000, available: available)])

    #expect(await provider.sample().value?.value == percent)
  }

  @Test(arguments: [(Int64(0), Int64(0)), (-1, 0), (1_000, 1_001), (1_000, -1)])
  func capacityThatCannotBeTrueFailsTheRead(total: Int64, available: Int64) async {
    let provider = await startedProvider([capacity(total: total, available: available)])

    guard case .unavailable(.sensorFailed) = await provider.sample().state else {
      Issue.record("\(available) of \(total) bytes must fail the read")
      return
    }

    #expect(await provider.errorState != nil)
  }

  @Test func failedReadSetsTheErrorStateAndTheNextReadWorks() async {
    let failure = SensorError("the startup disk reports no total or available capacity")

    let provider = await startedProvider([.failure(failure), capacity(total: 400, available: 100)])

    #expect(await provider.sample().state == .unavailable(.sensorFailed(failure)))
    #expect(await provider.sample().value?.value == 75)
    #expect(await provider.errorState == nil)
  }

  /// Every volume of an APFS container reports the container's size, so the capacity must equal what `statfs`,
  /// which `df` uses, reports for the root volume.
  @Test func liveSourceReadsTheStartupDisksContainer() throws {
    let live = try StartupVolumeCapacity().read()

    var root = statfs()

    #expect(statfs("/", &root) == 0)
    #expect(live.totalBytes == Int64(root.f_blocks) * Int64(root.f_bsize))
    #expect((0...live.totalBytes).contains(live.availableBytes))
  }

  @Test func liveSensorReadsAShareOfTheDisk() throws {
    var sensor = StorageSensor()

    try sensor.open()

    defer { sensor.close() }

    guard case .value(let reading) = try sensor.read() else {
      Issue.record("expected a value from the first read")
      return
    }

    #expect(reading.unit == .percent)
    #expect((0...100).contains(reading.value))
  }
}
