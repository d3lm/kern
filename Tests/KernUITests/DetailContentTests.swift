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
    let row = Metric.gpu.detailRow(for: readings(.gpu), source: source(.activeResidency), at: start)

    #expect(row.title == "GPU activity")
    #expect(!row.title.localizedCaseInsensitiveContains("usage"))
    #expect(row.explanation == "Active residency: the share of time it was powered on, not utilization")
  }

  @Test func temperatureIsExplainedByItsExactSource() {
    let description = "Hottest of the 10 CPU core sensors in the SMC validated for the M1 Max"

    let row = Metric.temperature.detailRow(
      for: readings(.temperature),
      source: source(.temperature, description),
      at: start
    )

    #expect(row.explanation == description)
  }

  @Test func usageAndMemoryAreExplainedByWhereTheyComeFrom() {
    let cpu = Metric.cpu.detailRow(for: readings(.cpu), source: source(.utilization, "Mach counters"), at: start)

    let memory = Metric.memory.detailRow(
      for: readings(.memory),
      source: source(.memoryUsage, "VM statistics"),
      at: start
    )

    #expect(cpu.explanation == "Mach counters")
    #expect(memory.explanation == "VM statistics")
  }

  @Test func cpuUsageDividesIntoUserAndSystemTimeFromTheSameSample() {
    let split = CPUTimeSplit(user: 17.6, system: 24.4)
    let cpu = readings(.cpu, after: [sample(.valid(MetricValue(42, .percent, split: split)), at: start)])

    let rows = Metric.cpu.detailLines.map {
      Metric.cpu.detailRow($0, for: cpu, source: source(.utilization), at: start)
    }

    #expect(Metric.cpu.detailLines == [.value, .userTime, .systemTime])
    #expect(rows.map(\.label) == ["Usage", "User", "System"])
    #expect(rows.map(\.title) == ["CPU usage", "CPU user time", "CPU system time"])
    #expect(rows.map(\.valueText) == ["42%", "18%", "24%"])
    #expect(Metric.gpu.detailLines == [.value])
  }

  @Test func cpuWithoutASplitHasNoUserOrSystemValue() {
    let cpu = readings(.cpu, after: [sample(value(42), at: start)])

    for line in [DetailLine.userTime, .systemTime] {
      let row = Metric.cpu.detailRow(line, for: cpu, source: source(.utilization), at: start)

      #expect((row.valueText, row.spokenValue) == ("—", "unavailable"))
    }
  }

  @Test func valuesAreWholeUnitsAndSpokenWithTheirUnit() {
    let percent = Metric.memory.detailRow(
      for: readings(.memory, after: [sample(value(86.6))]),
      source: source(.memoryUsage),
      at: start
    )

    let celsius = Metric.temperature.detailRow(
      for: readings(.temperature, after: [sample(value(68.4, .celsius))]),
      source: source(.temperature),
      at: start
    )

    #expect((percent.valueText, percent.spokenValue) == ("87%", "87 percent"))
    #expect((celsius.valueText, celsius.spokenValue) == ("68 °C", "68 degrees Celsius"))
  }

  @Test func currentValueSaysNothingAboutItsStatus() {
    let row = Metric.cpu.detailRow(
      for: readings(.cpu, after: [sample(value(23), at: start)]),
      source: source(.utilization),
      at: start + .seconds(1)
    )

    #expect(row.status == .current(acquiredAt: start))
    #expect(statusText(row, at: start + .seconds(1)) == nil)
  }

  @Test func staleValueKeepsItsNumberAndSaysSinceWhen() {
    let readings = readings(.cpu, after: [sample(value(23), at: start)])
    let row = Metric.cpu.detailRow(for: readings, source: source(.utilization), at: start + .seconds(5))

    #expect(row.valueText == "23%")
    #expect(row.isStale)
    #expect(statusText(row, at: start + .seconds(5)) == "Stale: not updated since 22:29:55")
  }

  @Test func userAndSystemTimeGoStaleWithTheValueAndLeaveTheStatusToIt() {
    let split = CPUTimeSplit(user: 10, system: 13)
    let cpu = readings(.cpu, after: [sample(.valid(MetricValue(23, .percent, split: split)), at: start)])

    for line in [DetailLine.userTime, .systemTime] {
      let row = Metric.cpu.detailRow(line, for: cpu, source: source(.utilization), at: start + .seconds(5))

      #expect(row.isStale)
      #expect(statusText(row, at: start + .seconds(5)) == nil)
    }
  }

  @Test func markingStaleChangesOnlyStaleness() {
    let cpu = readings(.cpu, after: [sample(value(23), at: start)])
    let current = Metric.cpu.detailRow(for: cpu, source: source(.utilization), at: start)
    let stale = Metric.cpu.detailRow(for: cpu, source: source(.utilization), at: start + .seconds(5))
    let waiting = Metric.cpu.detailRow(for: readings(.cpu), source: source(.utilization), at: start)
    let history = HistoryChart(levels: [nil, 4], span: .seconds(4), isStale: false)
    let cores = CoreChart(cores: CoreUtilization(performance: [1], efficiency: [2]), isStale: false)

    #expect(current.markedStale == stale)
    #expect(waiting.markedStale == waiting)
    #expect(history.markedStale == HistoryChart(levels: [nil, 4], span: .seconds(4), isStale: true))
    #expect(cores.markedStale == CoreChart(cores: cores.cores, isStale: true))
  }

  @Test func failedSampleKeepsTheLastValueCurrentUntilItGoesStale() {
    let readings = readings(.gpu, after: [sample(value(40), at: start), sample(failed, at: start + .seconds(2))])
    let row = Metric.gpu.detailRow(for: readings, source: source(.activeResidency), at: start + .seconds(4))

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
      at: start
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
    let row = Metric.cpu.detailRow(for: readings(.cpu, after: samples), source: source(.utilization), at: start)

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
    let chart = try #require(Metric.cpu.historyChart(for: readings(.cpu, after: samples), at: start))

    #expect(chart.levels == Array(repeating: nil, count: 57) + [12.4, nil, 57.6])
    #expect(chart.span == .seconds(120))
    #expect(chart.spokenSummary == "Last 2 minutes: lowest 12 percent, highest 58 percent")
    #expect(Metric.temperature.historyChart(for: readings(.temperature), at: start) == nil)
  }

  @Test func historyWithoutValuesSaysSo() throws {
    let chart = try #require(Metric.gpu.historyChart(for: readings(.gpu, after: [sample(failed)]), at: start))

    #expect(chart.spokenSummary == "No values in the last 2 minutes")
  }
}
