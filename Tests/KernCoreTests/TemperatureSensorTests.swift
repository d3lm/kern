import Testing

@testable import KernCore

/// Replays scripted readings in order, and logs which sensors it was opened with and each read.
struct ScriptedTemperatures: TemperatureSource {
  let log: SensorLog
  var reads: [Result<[String: Double], SensorError>]

  mutating func open(keys: [String]) throws(SensorError) {
    log.record("open \(keys.joined(separator: " "))")
  }

  mutating func read() throws(SensorError) -> [String: Double] {
    log.record("read")

    guard !reads.isEmpty else {
      Issue.record("unexpected read()")
      throw SensorError("unscripted read")
    }

    return try reads.removeFirst().get()
  }

  mutating func close() {
    log.record("close")
  }
}

/// Tests that read the real SMC check the M1 Max sensor map, so they only run on that chip.
let onM1Max = ChipIdentifier.current == .recognized(Chip(family: .m1, variant: .max))

struct TemperatureSensorTests {
  static let m1Max = ChipIdentity.recognized(Chip(family: .m1, variant: .max))
  static let m1MaxSensors = ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T", "Tp0X", "Tp0b"]

  let log = SensorLog()
  let failure = SensorError("SMC key Tp01 returned result 0x84")

  func startedProvider(chip: ChipIdentity = m1Max, _ reads: [Result<[String: Double], SensorError>]) async
    -> MetricProvider
  {
    let sensor = TemperatureSensor(chip: chip, temperatures: ScriptedTemperatures(log: log, reads: reads))
    let provider = MetricProvider(sensor: sensor)

    await provider.start()

    return provider
  }

  func startedProvider(_ reads: [[String: Double]]) async -> MetricProvider {
    await startedProvider(reads.map { .success($0) })
  }

  /// Every M1 Max sensor at `celsius`, except the ones in `overrides`.
  func m1Max(at celsius: Double, _ overrides: [String: Double] = [:]) -> [String: Double] {
    Dictionary(uniqueKeysWithValues: Self.m1MaxSensors.map { ($0, celsius) }).merging(overrides) { $1 }
  }

  @Test func m1MaxOpensExactlyItsVerifiedCPUSensors() async {
    _ = await startedProvider([m1Max(at: 50)])

    #expect(log.all == ["open " + Self.m1MaxSensors.joined(separator: " ")])
  }

  @Test func readingIsTheHottestVerifiedSensorInCelsius() async {
    let provider = await startedProvider([m1Max(at: 60, ["Tp09": 64, "Tp0H": 71.5])])

    let sample = await provider.sample()

    #expect(sample.state == .valid(MetricValue(71.5, .celsius)))
    #expect(sample.source == SourceID("temperature.smc.cpu"))
    #expect(sample.quantity == .temperature)
    #expect(await provider.lastSuccessfulSample == sample)
  }

  /// A battery, storage, ambient, or GPU sensor must never become the CPU temperature, even when it is hotter.
  @Test func sensorsOutsideTheMapDoNotContributeToTheValue() async {
    let provider = await startedProvider([m1Max(at: 60, ["TB0T": 125, "TH0x": 110, "TaLP": 90, "Tg05": 99])])

    #expect(await provider.sample().state == .valid(MetricValue(60, .celsius)))
  }

  @Test(arguments: [
    ChipIdentity.recognized(Chip(family: .m1, variant: .base)),
    .recognized(Chip(family: .m1, variant: .pro)),
    .recognized(Chip(family: .m1, variant: .ultra)),
    .recognized(Chip(family: .m2, variant: .max)),
    .recognized(Chip(family: .m5, variant: .pro)),
    .unrecognized(brandString: "Apple M6 Max"),
    .unrecognized(brandString: nil),
  ])
  func chipWithoutAValidatedMapIsUnavailableAndReadsNoSensors(chip: ChipIdentity) async {
    let provider = await startedProvider(chip: chip, [.success(m1Max(at: 50))])

    guard case .unavailable(let error) = await provider.availability else {
      Issue.record("expected the provider to be unavailable after start")
      return
    }

    let sample = await provider.sample()

    #expect(sample.state == .unavailable(.sensorFailed(error)))
    #expect(log.all.isEmpty)
  }

  @Test(arguments: [0, 9.99, 130.01, -40, 1_000, .nan, .infinity, -.infinity])
  func implausibleValueIsRejected(celsius: Double) async {
    let provider = await startedProvider([m1Max(at: 60, ["Tp0P": celsius])])

    let sample = await provider.sample()

    guard case .unavailable(.sensorFailed(let error)) = sample.state else {
      Issue.record("expected a rejected reading, got \(sample.state)")
      return
    }

    #expect(error.description.contains("Tp0P"))
    #expect(await provider.lastSuccessfulSample == nil)
  }

  @Test func valuesAtTheEdgesOfThePlausibleRangeAreAccepted() async {
    let provider = await startedProvider([m1Max(at: 10), m1Max(at: 10, ["Tp0b": 130])])

    #expect(await provider.sample().state == .valid(MetricValue(10, .celsius)))
    #expect(await provider.sample().state == .valid(MetricValue(130, .celsius)))
  }

  @Test func readMissingASensorFails() async {
    var reading = m1Max(at: 60)

    reading["Tp0T"] = nil

    let provider = await startedProvider([reading])

    let sample = await provider.sample()

    guard case .unavailable(.sensorFailed(let error)) = sample.state else {
      Issue.record("expected a failed read, got \(sample.state)")
      return
    }

    #expect(error.description.contains("Tp0T"))
  }

  @Test func failedReadIsUnavailableAndTheNextReadRecovers() async {
    let provider = await startedProvider([.failure(failure), .success(m1Max(at: 55))])

    let failed = await provider.sample()

    #expect(failed.state == .unavailable(.sensorFailed(failure)))
    #expect(await provider.errorState == failure)

    let recovered = await provider.sample()

    #expect(recovered.state == .valid(MetricValue(55, .celsius)))
    #expect(await provider.errorState == nil)
  }

  @Test func samplesReadTheMapsSensorsWithoutRediscoveringThem() async {
    let provider = await startedProvider([m1Max(at: 50), m1Max(at: 51), m1Max(at: 52)])

    for _ in 0..<3 {
      _ = await provider.sample()
    }

    await provider.stop()

    #expect(log.all == ["open " + Self.m1MaxSensors.joined(separator: " "), "read", "read", "read", "close"])
  }

  /// Changing this list means validating the new sensors on the chip and recording them in `docs/sensors.md`.
  @Test func onlyTheM1MaxHasAValidatedSensorMap() {
    let m1Max = Chip(family: .m1, variant: .max)

    #expect(Array(CPUTemperatureMap.validated.keys) == [m1Max])
    #expect(CPUTemperatureMap.validated[m1Max] == CPUTemperatureMap(sensors: Self.m1MaxSensors, aggregation: .maximum))
  }

  @Test(.enabled(if: onM1Max)) func smcReadsEveryM1MaxSensorWithinThePlausibleRange() throws {
    var smc = SMCTemperatures()

    try smc.open(keys: Self.m1MaxSensors)

    defer { smc.close() }

    let reading = try smc.read()

    #expect(reading.keys.sorted() == Self.m1MaxSensors.sorted())
    #expect(reading.values.allSatisfy { (10...130).contains($0) })
  }

  @Test(.enabled(if: onM1Max), arguments: ["Tzz9", "#KEY", "TG0B", "Tp0"])
  func smcRefusesKeysThatAreMissingOrNotFloatTemperatures(key: String) {
    var smc = SMCTemperatures()

    defer { smc.close() }

    #expect(throws: SensorError.self) { try smc.open(keys: ["Tp01", key]) }
  }

  @Test(.enabled(if: onM1Max)) func liveSensorGivesAPlausibleCelsiusReading() throws {
    var sensor = TemperatureSensor(chip: ChipIdentifier.current)

    try sensor.open()

    defer { sensor.close() }

    guard case .value(let reading) = try sensor.read() else {
      Issue.record("expected a value from the first read")
      return
    }

    #expect(reading.unit == .celsius)
    #expect((10...130).contains(reading.value))
  }

  @Test(.enabled(if: onM1Max)) func surveyListsTheMapsSensorsAmongEveryTemperature() throws {
    var survey = try TemperatureSurvey()

    defer { survey.close() }

    let reading = try survey.read()

    #expect(Set(Self.m1MaxSensors).isSubset(of: survey.sensors))
    #expect(survey.sensors.contains("TB0T"))
    #expect(reading.keys.sorted() == survey.sensors.sorted())
  }
}
