import KernCore
import Synchronization
import Testing

@testable import KernUI

final class SensorCalls: Sendable {
  private let calls = Mutex<[String]>([])

  func record(_ call: String) {
    calls.withLock { $0.append(call) }
  }

  var all: [String] { calls.withLock { $0 } }
}

struct RecordingSensor: MetricSensor {
  let source = SourceID("test.recording")
  let quantity = MetricQuantity.activeResidency
  let sourceDescription = "Records each call"
  var coreKinds: [CoreKind]? = nil
  let calls: SensorCalls

  mutating func open() throws(SensorError) {
    calls.record("open")
  }

  mutating func read() throws(SensorError) -> SensorReading {
    calls.record("read")

    return .value(MetricValue(12, .percent))
  }

  mutating func close() {
    calls.record("close")
  }
}

#if DEBUG
  struct DebugLaunchOptionsTests {
    let calls = SensorCalls()

    @Test func readsFailuresAndChipAndIgnoresEveryOtherArgument() throws {
      let options = try DebugLaunchOptions(arguments: [
        "/Applications/Kern.app/Contents/MacOS/Kern",
        "-NSDocumentRevisionsDebugMode", "YES",
        "--fail", "gpu",
        "--fail", "temperature:30",
        "--chip", "Apple M3 Pro",
      ])

      #expect(options.failures == [.gpu: .always, .temperature: .during(.seconds(30))])
      #expect(options.chip == .recognized(Chip(family: .m3, variant: .pro)))
    }

    @Test func noArgumentsChangeNothing() throws {
      let options = try DebugLaunchOptions(arguments: ["Kern"])

      #expect(options.failures.isEmpty)
      #expect(options.chip == nil)
    }

    @Test func chipThatIsNotAppleSiliconIsUnrecognized() throws {
      let options = try DebugLaunchOptions(arguments: ["Kern", "--chip", "Intel(R) Core(TM) i9"])

      #expect(options.chip == .unrecognized(brandString: "Intel(R) Core(TM) i9"))
    }

    @Test(arguments: [
      ["--fail"],
      ["--fail", "disk"],
      ["--fail", "gpu:"],
      ["--fail", "gpu:0"],
      ["--fail", "gpu:-5"],
      ["--fail", "gpu:ten"],
      ["--fail", "gpu:5:5"],
      ["--chip"],
    ])
    func rejectsArgumentsItCannotUse(arguments: [String]) {
      #expect(throws: DebugLaunchOptions.InvalidArgument.self) {
        try DebugLaunchOptions(arguments: ["Kern"] + arguments)
      }
    }

    @Test func onlyTheNamedMetricsSensorFails() throws {
      let options = try DebugLaunchOptions(arguments: ["Kern", "--fail", "gpu"])
      var gpu = options.sensor(RecordingSensor(calls: calls), for: .gpu, launchedAt: .now)
      var cpu = options.sensor(RecordingSensor(calls: calls), for: .cpu, launchedAt: .now)

      #expect(throws: SensorError("failure forced by --fail")) { try gpu.read() }
      #expect(try cpu.read() == .value(MetricValue(12, .percent)))
    }

    @Test func failingSensorFailsEveryReadButOpensAndClosesTheRealOne() throws {
      var sensor = FailingSensor(base: RecordingSensor(calls: calls), failsUntil: nil)
      var cpuWithCores = RecordingSensor(calls: SensorCalls())

      cpuWithCores.coreKinds = [.efficiency, .performance]

      try sensor.open()

      #expect(throws: SensorError.self) { try sensor.read() }

      sensor.close()

      #expect(calls.all == ["open", "close"])
      #expect(sensor.source == SourceID("test.recording"))
      #expect(sensor.quantity == .activeResidency)
      #expect(FailingSensor(base: cpuWithCores, failsUntil: nil).coreKinds == [.efficiency, .performance])
      #expect(sensor.sourceDescription == "Records each call")
    }

    @Test func failingSensorReadsTheRealOneOnceItsTimeIsUp() throws {
      var failing = FailingSensor(base: RecordingSensor(calls: calls), failsUntil: .now + .seconds(60))
      var recovered = FailingSensor(base: RecordingSensor(calls: calls), failsUntil: .now)

      #expect(throws: SensorError.self) { try failing.read() }
      #expect(try recovered.read() == .value(MetricValue(12, .percent)))
      #expect(calls.all == ["read"])
    }

    @Test func failureForSecondsCountsFromLaunch() throws {
      let options = try DebugLaunchOptions(arguments: ["Kern", "--fail", "cpu:30"])
      var launchedLongAgo = options.sensor(RecordingSensor(calls: calls), for: .cpu, launchedAt: .now - .seconds(31))
      var launchedJustNow = options.sensor(RecordingSensor(calls: calls), for: .cpu, launchedAt: .now)

      #expect(try launchedLongAgo.read() == .value(MetricValue(12, .percent)))
      #expect(throws: SensorError.self) { try launchedJustNow.read() }
    }
  }
#endif
