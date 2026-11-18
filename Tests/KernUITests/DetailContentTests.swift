import Foundation
import KernCore
import Testing

@testable import KernUI

func source(
  _ quantity: MetricQuantity,
  _ description: String = "Test source",
  coreKinds: [CoreKind]? = nil
) -> MetricSource {
  MetricSource(id: SourceID("test.sensor"), quantity: quantity, description: description, coreKinds: coreKinds)
}

@MainActor
struct DetailContentTests {
  let date = Date(timeIntervalSince1970: 1_794_778_200)

  /// A fixed locale and time zone, so the times read the same wherever the test runs.
  let timeStyle = Date.FormatStyle(
    date: .omitted,
    time: .standard,
    locale: Locale(identifier: "en_GB"),
    timeZone: TimeZone(identifier: "Europe/Berlin")!
  )

  func statusText(_ row: DetailRow, at now: ContinuousClock.Instant) -> String? {
    row.statusText(at: now, date: date, timeStyle: timeStyle)
  }

  @Test func titlesNameWhatEachNumberMeasures() {
    #expect(Metric.cpu.detailTitle(measuring: .utilization) == "CPU usage")
    #expect(Metric.gpu.detailTitle(measuring: .activeResidency) == "GPU activity")
    #expect(Metric.gpu.detailTitle(measuring: .utilization) == "GPU usage")
    #expect(Metric.temperature.detailTitle(measuring: .temperature) == "CPU temperature")
    #expect(Metric.memory.detailTitle(measuring: .memoryUsage) == "Memory used")
    #expect(Metric.memoryPressure.detailTitle(measuring: .memoryPressure) == "Memory pressure")
  }

  @Test func gpuActivityIsExplainedAsActiveResidencyNotUtilization() {
    let row = Metric.gpu.detailRow(
      for: readings(.gpu), source: source(.activeResidency), at: start, temperatureUnit: .celsius)

    #expect(row.title == "GPU activity")
    #expect(!row.title.localizedCaseInsensitiveContains("usage"))
    #expect(row.explanation == "Active residency: the share of time it was powered on, not utilization")
  }

  @Test func temperatureIsExplainedByItsExactSource() {
    let description = "Hottest of the 10 CPU core sensors in the SMC validated for the M1 Max"

    let row = Metric.temperature.detailRow(
      for: readings(.temperature),
      source: source(.temperature, description),
      at: start, temperatureUnit: .celsius
    )

    #expect(row.explanation == description)
  }

  @Test func usageAndMemoryAreExplainedByWhereTheyComeFrom() {
    let cpu = Metric.cpu.detailRow(
      for: readings(.cpu), source: source(.utilization, "Mach counters"), at: start, temperatureUnit: .celsius)

    let memory = Metric.memory.detailRow(
      for: readings(.memory),
      source: source(.memoryUsage, "VM statistics"),
      at: start, temperatureUnit: .celsius
    )

    #expect(cpu.explanation == "Mach counters")
    #expect(memory.explanation == "VM statistics")
  }

  @Test func cpuExplanationAddsUserAndSystemTimeFromTheSameSample() {
    let split = CPUTimeSplit(user: 17.6, system: 24.4)
    let cpu = readings(.cpu, after: [sample(.valid(MetricValue(42, .percent, split: split)), at: start)])

    let row = Metric.cpu.detailRow(
      for: cpu, source: source(.utilization, "Mach counters"), at: start, temperatureUnit: .celsius)

    #expect(row.valueText == "42%")
    #expect(row.explanation == "Mach counters\nUser 18% (apps), system 24% (macOS kernel)")
  }

  @Test func valuesAreWholeUnitsAndSpokenWithTheirUnit() {
    let percent = Metric.memory.detailRow(
      for: readings(.memory, after: [sample(value(86.6))]),
      source: source(.memoryUsage),
      at: start, temperatureUnit: .celsius
    )

    let celsius = Metric.temperature.detailRow(
      for: readings(.temperature, after: [sample(value(68.4, .celsius))]),
      source: source(.temperature),
      at: start, temperatureUnit: .celsius
    )

    #expect((percent.valueText, percent.spokenValue) == ("87%", "87 percent"))
    #expect((celsius.valueText, celsius.spokenValue) == ("68°", "68 degrees Celsius"))
    #expect((celsius.numberText, celsius.unitText) == ("68", "°"))
  }

  @Test func currentValueSaysNothingAboutItsStatus() {
    let row = Metric.cpu.detailRow(
      for: readings(.cpu, after: [sample(value(23), at: start)]),
      source: source(.utilization),
      at: start + .seconds(1), temperatureUnit: .celsius
    )

    #expect(row.status == .current(acquiredAt: start))
    #expect(statusText(row, at: start + .seconds(1)) == nil)
  }

  @Test func staleValueKeepsItsNumberAndSaysSinceWhen() {
    let readings = readings(.cpu, after: [sample(value(23), at: start)])

    let row = Metric.cpu.detailRow(
      for: readings, source: source(.utilization), at: start + .seconds(5), temperatureUnit: .celsius)

    #expect(row.valueText == "23%")
    #expect(row.isStale)
    #expect(statusText(row, at: start + .seconds(5)) == "Stale: not updated since 22:29:55")
  }

  @Test func failedSampleKeepsTheLastValueCurrentUntilItGoesStale() {
    let readings = readings(.gpu, after: [sample(value(40), at: start), sample(failed, at: start + .seconds(2))])

    let row = Metric.gpu.detailRow(
      for: readings, source: source(.activeResidency), at: start + .seconds(4), temperatureUnit: .celsius)

    #expect(row.valueText == "40%")
    #expect(row.status == .current(acquiredAt: start))
  }

  @Test(arguments: [
    ([sample(.unavailable(.noValue(.countersUnchanged)))], "No value: the counters did not advance"),
    ([sample(.unavailable(.noValue(.countersWentBackwards)))], "No value: the counters went backwards"),
    (
      [sample(.unavailable(.sensorFailed(SensorError("no validated CPU temperature sensor map for chip: M3 Pro"))))],
      "Unavailable: no validated CPU temperature sensor map for chip: M3 Pro"
    ),
  ])
  func metricWithoutAValueSaysWhyInWords(samples: [MetricSample], text: String) {
    let row = Metric.temperature.detailRow(
      for: readings(.temperature, after: samples),
      source: source(.temperature),
      at: start, temperatureUnit: .celsius
    )

    #expect(row.valueText == "—")
    #expect(row.spokenValue == "unavailable")
    #expect(statusText(row, at: start) == text)
  }

  @Test(arguments: [
    [],
    [sample(.unavailable(.notStarted))],
    [sample(.unavailable(.noValue(.awaitingBaseline)))],
  ])
  func firstValueOnItsWayIsMeasuringWithoutWords(samples: [MetricSample]) {
    let row = Metric.cpu.detailRow(
      for: readings(.cpu, after: samples), source: source(.utilization), at: start, temperatureUnit: .celsius)

    #expect(row.isMeasuring)
    #expect(row.valueText == "—")
    #expect(row.spokenValue == "measuring")
    #expect(statusText(row, at: start) == nil)
  }

  @Test func coreChartShowsTheCoresOfTheSameSampleAsTheValue() {
    let cores = CoreUtilization(performance: [50, 30], efficiency: [90])

    let withCores = MetricSample(
      source: SourceID("test.sensor"),
      quantity: .utilization,
      acquiredAt: start,
      state: .valid(MetricValue(56.7, .percent, cores: cores))
    )

    let readings = readings(.cpu, after: [withCores, sample(failed, at: start + .seconds(2))])

    let chart = Metric.cpu.coreChart(for: readings, at: start + .seconds(2))

    #expect(chart == CoreChart(cores: cores, isStale: false))
    #expect(chart.spokenSummary == "Performance cores: 50, 30 percent. Efficiency cores: 90 percent")
    #expect(Metric.cpu.coreChart(for: readings, at: start + .seconds(5)).isStale)
  }

  @Test func coreChartWithoutCoresIsSpokenAsUnavailable() {
    let chart = Metric.cpu.coreChart(for: readings(.cpu, after: [sample(value(20))]), at: start)

    #expect(chart.cores == nil)
    #expect(chart.spokenSummary == "unavailable")
  }

  @Test func historyChartCoversTheWholeHistoryAndSummarizesItInWords() throws {
    let samples = [sample(value(12.4)), sample(failed), sample(value(57.6))]

    let chart = try #require(
      Metric.cpu.historyChart(for: readings(.cpu, after: samples), at: start, temperatureUnit: .celsius))

    #expect(chart.levels == Array(repeating: nil, count: 57) + [12.4, nil, 57.6])
    #expect(chart.span == .seconds(120))
    #expect(chart.spokenSummary == "Last 2 minutes: lowest 12 percent, highest 58 percent")
    #expect(Metric.memory.historyChart(for: readings(.memory), at: start, temperatureUnit: .celsius) == nil)
  }

  @Test func temperatureHistoryCoversTenMinutesInDegrees() throws {
    let samples = [sample(value(61.6, .celsius)), sample(value(88.6, .celsius))]

    let chart = try #require(
      Metric.temperature.historyChart(
        for: readings(.temperature, interval: .seconds(10), after: samples), at: start, temperatureUnit: .celsius))

    #expect(chart.unit == .degrees(.celsius))
    #expect(chart.spokenSummary == "Last 10 minutes: lowest 62 degrees Celsius, highest 89 degrees Celsius")
  }

  @Test func historyWithoutValuesSaysSo() throws {
    let chart = try #require(
      Metric.gpu.historyChart(for: readings(.gpu, after: [sample(failed)]), at: start, temperatureUnit: .celsius))

    #expect(chart.spokenSummary == "No values in the last 2 minutes")
  }

  @Test(arguments: [
    (UInt64(29_850_000_000), UInt64(32) << 30, "27.8 / 32 GB", "27.8 of 32 gigabytes"),
    (UInt64(1) << 29, UInt64(8) << 30, "0.5 / 8 GB", "0.5 of 8 gigabytes"),
    (UInt64(3) << 29, UInt64(3) << 29, "1.5 / 1.5 GB", "1.5 of 1.5 gigabytes"),
  ])
  func usedMemoryIsInGigabytesOfTheInstalledMemory(used: UInt64, installed: UInt64, text: String, spoken: String) {
    let memory = MemoryText(MemoryAmount(usedBytes: used, installedBytes: installed))

    #expect((memory.text, memory.spokenText) == (text, spoken))
  }

  @Test func sensorRangeShowsItsHottestAndSaysItsRange() {
    let range = SensorRange(PartTemperature(part: .cpu, coolest: 75.6, hottest: 88.6), unit: .celsius)
    let single = SensorRange(PartTemperature(part: .cpu, coolest: 60.2, hottest: 59.8), unit: .celsius)

    #expect((range.label, range.valueText) == ("CPU", "89°"))
    #expect(range.spokenText == "CPU sensors, 76 to 89 degrees Celsius")
    #expect(single.spokenText == "CPU sensors, 60 degrees Celsius")
  }

  @Test func coreKindsShowTheMeanOfTheirCores() {
    #expect(CoreChart.mean([88, 92, 85, 79, 70, 66, 70, 66]) == 77)
    #expect(CoreChart.mean([]) == nil)
  }

  @Test func headerNamesTheChipWithoutApple() {
    #expect(ChipIdentity.recognized(Chip(family: .m1, variant: .max)).name == "M1 Max")
    #expect(ChipIdentity(brandString: "Apple M6 Max").name == "M6 Max")
    #expect(ChipIdentity.unrecognized(brandString: nil).name == nil)
  }
}
