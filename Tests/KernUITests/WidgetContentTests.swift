import KernCore
import Testing

@testable import KernUI

@MainActor
struct WidgetContentTests {
  @Test func temperatureIsADashUntilTheFirstValidReading() {
    let noSamples = readings(.temperature)
    let onlyFailures = readings(.temperature, after: [sample(failed), sample(failed, at: start + .seconds(10))])

    #expect(Widget.temperature.content(for: noSamples, at: start, temperatureUnit: .celsius) == .noReading)
    #expect(Widget.temperature.content(for: onlyFailures, at: start, temperatureUnit: .celsius) == .noReading)
  }

  @Test func temperatureIsWholeDegrees() {
    for (celsius, text) in [(46.4, "46°"), (46.5, "47°"), (9.6, "10°"), (129.7, "130°")] {
      let readings = readings(.temperature, after: [sample(value(celsius, .celsius))])

      #expect(
        Widget.temperature.content(for: readings, at: start, temperatureUnit: .celsius)
          == .reading(text, isStale: false))
    }
  }

  @Test func temperatureInFahrenheitIsWholeDegreesFahrenheit() {
    for (celsius, text) in [(46.4, "116°"), (0, "32°"), (100, "212°"), (130, "266°")] {
      let readings = readings(.temperature, after: [sample(value(celsius, .celsius))])

      #expect(
        Widget.temperature.content(for: readings, at: start, temperatureUnit: .fahrenheit)
          == .reading(text, isStale: false))
    }
  }

  @Test func gaugeIgnoresTheTemperatureUnit() {
    let readings = readings(.gpu, after: [sample(value(40))])

    #expect(
      Widget.gpu.content(for: readings, at: start, temperatureUnit: .fahrenheit) == .level(.percent(40), isStale: false)
    )
  }

  @Test func gpuHasNoLevelWhenItsProviderHasNeverHadAValue() {
    let unavailable = readings(
      .gpu,
      after: [
        sample(.unavailable(.noValue(.awaitingBaseline))),
        sample(failed, at: start + .seconds(2)),
        sample(.unavailable(.notStarted), at: start + .seconds(4)),
      ])

    #expect(
      Widget.gpu.content(for: unavailable, at: start + .seconds(4), temperatureUnit: .celsius)
        == .level(.unavailable, isStale: false))
  }

  @Test func gaugeIsMeasuringUntilTheFirstValueAndUnavailableWithoutOneForAnyOtherReason() {
    let measuring = [[], [sample(.unavailable(.noValue(.awaitingBaseline)))]]

    let unavailable = [
      [sample(failed)],
      [sample(.unavailable(.noValue(.countersUnchanged)))],
      [sample(.unavailable(.noValue(.awaitingBaseline))), sample(failed, at: start + .seconds(2))],
    ]

    for samples in measuring {
      #expect(
        Widget.gpu.content(for: readings(.gpu, after: samples), at: start, temperatureUnit: .celsius)
          == .level(.measuring, isStale: false))
    }

    for samples in unavailable {
      #expect(
        Widget.gpu.content(for: readings(.gpu, after: samples), at: start, temperatureUnit: .celsius)
          == .level(.unavailable, isStale: false))
    }

    let restarted = readings(.gpu, after: [sample(value(40)), sample(.unavailable(.noValue(.awaitingBaseline)))])

    #expect(
      Widget.gpu.content(for: restarted, at: start, temperatureUnit: .celsius) == .level(.percent(40), isStale: false))
  }

  @Test func gpuIsWholePercent() {
    for (percent, level) in [(0.0, 0), (4.6, 5), (99.5, 100), (100.0, 100)] {
      let readings = readings(.gpu, after: [sample(value(percent))])

      #expect(
        Widget.gpu.content(for: readings, at: start, temperatureUnit: .celsius)
          == .level(.percent(level), isStale: false))
    }
  }

  @Test func memoryPressureIsALevelInWholePercentOrNoneWithoutAValue() {
    let pressure = readings(.memoryPressure, interval: .seconds(5), after: [sample(value(62.4))])
    let unavailable = readings(.memoryPressure, interval: .seconds(5), after: [sample(failed)])

    #expect(
      Widget.memory.content(for: pressure, at: start, temperatureUnit: .celsius) == .level(.percent(62), isStale: false)
    )

    #expect(
      Widget.memory.content(for: pressure, at: start + .seconds(11), temperatureUnit: .celsius)
        == .level(.percent(62), isStale: true))

    #expect(
      Widget.memory.content(for: unavailable, at: start, temperatureUnit: .celsius)
        == .level(.unavailable, isStale: false))
  }

  @Test func failedSampleKeepsShowingTheLastValueUntilItGoesStale() {
    let readings = readings(.gpu, after: [sample(value(40)), sample(failed, at: start + .seconds(2))])

    #expect(
      Widget.gpu.content(for: readings, at: start + .seconds(4), temperatureUnit: .celsius)
        == .level(.percent(40), isStale: false))

    #expect(
      Widget.gpu.content(for: readings, at: start + .seconds(5), temperatureUnit: .celsius)
        == .level(.percent(40), isStale: true))
  }

  @Test func staleTemperatureKeepsItsValueAndIsMarkedStale() {
    let readings = readings(.temperature, interval: .seconds(10), after: [sample(value(55, .celsius))])

    #expect(
      Widget.temperature.content(for: readings, at: start + .seconds(20), temperatureUnit: .celsius)
        == .reading("55°", isStale: false))

    #expect(
      Widget.temperature.content(for: readings, at: start + .seconds(21), temperatureUnit: .celsius)
        == .reading("55°", isStale: true))
  }

  @Test func graphHasOneSlotPerHistorySampleNewestLastAndGapsAreNotZero() {
    let readings = readings(
      .cpu,
      after: [
        sample(.unavailable(.noValue(.awaitingBaseline))),
        sample(value(0), at: start + .seconds(2)),
        sample(failed, at: start + .seconds(4)),
        sample(value(75), at: start + .seconds(6)),
      ])

    guard
      case .graph(let levels, let isStale) = Widget.cpu.content(
        for: readings, at: start + .seconds(6), temperatureUnit: .celsius)
    else {
      Issue.record("the CPU widget draws a graph")
      return
    }

    #expect(levels.count == 60)
    #expect(levels.prefix(56).allSatisfy { $0 == nil })
    #expect(Array(levels.suffix(4)) == [nil, 0, nil, 75])
    #expect(!isStale)
  }

  @Test func graphKeepsOnlyTheLatestSixtySamples() {
    let samples = (0..<100).map { sample(value(Double($0)), at: start + .seconds(2 * $0)) }
    let readings = readings(.cpu, after: samples)

    let content = Widget.cpu.content(for: readings, at: start + .seconds(198), temperatureUnit: .celsius)

    #expect(content == .graph((40..<100).map(Double.init), isStale: false))
  }

  @Test func coresAreABarForEachCoreWithThePerformanceCoresFirst() {
    let cores = CoreUtilization(performance: [80, 61.5, 0], efficiency: [12, 100])
    let readings = readings(.cpu, after: [sample(value(50.7, cores: cores))])

    #expect(
      Widget.cores.content(for: readings, at: start, temperatureUnit: .celsius)
        == .bars([80, 61.5, 0, 12, 100], isStale: false))
  }

  @Test func coresWithoutPerCoreValuesAreTheOutlineAlone() {
    let noCores = [
      [], [sample(.unavailable(.noValue(.awaitingBaseline)))], [sample(failed)], [sample(value(40))],
    ]

    for samples in noCores {
      #expect(
        Widget.cores.content(for: readings(.cpu, after: samples), at: start, temperatureUnit: .celsius)
          == .bars([], isStale: false))
    }
  }

  @Test func failedCPUSampleKeepsTheLastBarsUntilTheyGoStale() {
    let cores = CoreUtilization(performance: [30], efficiency: [70])
    let readings = readings(.cpu, after: [sample(value(50, cores: cores)), sample(failed, at: start + .seconds(2))])

    #expect(
      Widget.cores.content(for: readings, at: start + .seconds(4), temperatureUnit: .celsius)
        == .bars([30, 70], isStale: false))

    #expect(
      Widget.cores.content(for: readings, at: start + .seconds(5), temperatureUnit: .celsius)
        == .bars([30, 70], isStale: true))
  }

  @Test func storageIsALevelWithItsReadingInWholePercent() {
    for (percent, level) in [(0.0, 0), (49.5, 50), (88.46, 88), (100.0, 100)] {
      let readings = readings(.storage, interval: .seconds(10), after: [sample(value(percent))])

      #expect(
        Widget.storage.content(for: readings, at: start, temperatureUnit: .fahrenheit)
          == .levelReading(.percent(level), isStale: false))
    }
  }

  @Test func storageWithoutAValueIsMeasuringUntilItsFirstSampleAndUnavailableAfterAFailure() {
    #expect(
      Widget.storage.content(for: readings(.storage), at: start, temperatureUnit: .celsius)
        == .levelReading(.measuring, isStale: false))

    #expect(
      Widget.storage.content(for: readings(.storage, after: [sample(failed)]), at: start, temperatureUnit: .celsius)
        == .levelReading(.unavailable, isStale: false))
  }

  @Test func kernUsageIsADashUntilTheFirstValue() {
    let noValues = [
      [], [sample(.unavailable(.noValue(.awaitingBaseline)))], [sample(failed)],
      [sample(.unavailable(.noValue(.countersUnchanged)))],
    ]

    for samples in noValues {
      #expect(
        Widget.kern.content(for: readings(.kern, after: samples), at: start, temperatureUnit: .celsius) == .noReading)
    }
  }

  @Test func kernUsageStacksItsCPUShareAboveItsFootprint() {
    let readings = readings(.kern, after: [sample(usage(0.43, megabytes: 17.6))])

    #expect(
      Widget.kern.content(for: readings, at: start, temperatureUnit: .fahrenheit)
        == .stacked("0.4%", "18 MB", isStale: false))
  }

  @Test(arguments: [
    (0.0, "0.0%"), (0.04, "0.0%"), (0.06, "0.1%"), (2.35, "2.4%"), (9.94, "9.9%"), (9.96, "10%"), (12.5, "13%"),
    (99.6, "100%"), (450, "450%"),
  ])
  func kernCPUKeepsATenthOfAPercentOnlyBelowTenPercent(percent: Double, text: String) {
    #expect(WidgetContent.processCPUText(percent) == text)
  }

  @Test(arguments: [(0.4, "0 MB"), (13.5, "14 MB"), (61.2, "61 MB"), (999.4, "999 MB")])
  func kernFootprintIsWholeMegabytesOfTwoToTheTwentiethBytes(megabytes: Double, text: String) {
    #expect(WidgetContent.footprintText(UInt64(megabytes * Double(1 << 20))) == text)
  }

  @Test func staleKernUsageKeepsItsValuesAndIsMarkedStale() throws {
    let readings = readings(.kern, after: [sample(usage(1.2, megabytes: 20), at: start)])
    let deadline = try #require(readings.staleAt)

    #expect(
      Widget.kern.content(for: readings, at: deadline - .nanoseconds(1), temperatureUnit: .celsius)
        == .stacked("1.2%", "20 MB", isStale: false))

    #expect(
      Widget.kern.content(for: readings, at: deadline, temperatureUnit: .celsius)
        == .stacked("1.2%", "20 MB", isStale: true))
  }

  @Test func readingsAtTheirStaleDeadlineChangeOnlyTheStaleness() throws {
    let levels = Array(repeating: nil, count: 59) + [47.0]
    let cores = CoreUtilization(performance: [47], efficiency: [46])

    let contents: [(Widget, MetricUnit, (Bool) -> WidgetContent)] = [
      (.temperature, .celsius, { .reading("47°", isStale: $0) }),
      (.gpu, .percent, { .level(.percent(47), isStale: $0) }),
      (.memory, .percent, { .level(.percent(47), isStale: $0) }),
      (.storage, .percent, { .levelReading(.percent(47), isStale: $0) }),
      (.cpu, .percent, { .graph(levels, isStale: $0) }),
      (.cores, .percent, { .bars([47, 46], isStale: $0) }),
    ]

    for (widget, unit, content) in contents {
      let readings = readings(widget.metric, after: [sample(value(47, unit, cores: cores), at: start)])
      let deadline = try #require(readings.staleAt)

      #expect(
        widget.content(for: readings, at: deadline - .nanoseconds(1), temperatureUnit: .celsius) == content(false),
        "\(widget)")

      #expect(widget.content(for: readings, at: deadline, temperatureUnit: .celsius) == content(true), "\(widget)")
    }
  }
}
