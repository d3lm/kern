import KernCore
import Testing

@testable import KernUI

@MainActor
struct WidgetContentTests {
  @Test func temperatureIsADashUntilTheFirstValidReading() {
    let noSamples = readings(.temperature)
    let onlyFailures = readings(.temperature, after: [sample(failed), sample(failed, at: start + .seconds(10))])

    #expect(Widget.temperature.content(for: noSamples, at: start) == .reading("—", isStale: false))
    #expect(Widget.temperature.content(for: onlyFailures, at: start) == .reading("—", isStale: false))
  }

  @Test func temperatureIsWholeDegrees() {
    for (celsius, text) in [(46.4, "46°"), (46.5, "47°"), (9.6, "10°"), (129.7, "130°")] {
      let readings = readings(.temperature, after: [sample(value(celsius, .celsius))])

      #expect(Widget.temperature.content(for: readings, at: start) == .reading(text, isStale: false))
    }
  }

  @Test func gpuHasNoLevelWhenItsProviderHasNeverHadAValue() {
    let unavailable = readings(
      .gpu,
      after: [
        sample(.unavailable(.noValue(.awaitingBaseline))),
        sample(failed, at: start + .seconds(2)),
        sample(.unavailable(.notStarted), at: start + .seconds(4)),
      ])

    #expect(Widget.gpu.content(for: unavailable, at: start + .seconds(4)) == .level(.unavailable, isStale: false))
  }

  @Test func gaugeIsMeasuringUntilTheFirstValueAndUnavailableWithoutOneForAnyOtherReason() {
    let measuring = [[], [sample(.unavailable(.noValue(.awaitingBaseline)))]]
    let unavailable = [
      [sample(failed)],
      [sample(.unavailable(.noValue(.countersUnchanged)))],
      [sample(.unavailable(.noValue(.awaitingBaseline))), sample(failed, at: start + .seconds(2))],
    ]

    for samples in measuring {
      #expect(Widget.gpu.content(for: readings(.gpu, after: samples), at: start) == .level(.measuring, isStale: false))
    }

    for samples in unavailable {
      #expect(
        Widget.gpu.content(for: readings(.gpu, after: samples), at: start) == .level(.unavailable, isStale: false))
    }

    let restarted = readings(.gpu, after: [sample(value(40)), sample(.unavailable(.noValue(.awaitingBaseline)))])

    #expect(Widget.gpu.content(for: restarted, at: start) == .level(.percent(40), isStale: false))
  }

  @Test func gpuIsWholePercent() {
    for (percent, level) in [(0.0, 0), (4.6, 5), (99.5, 100), (100.0, 100)] {
      let readings = readings(.gpu, after: [sample(value(percent))])

      #expect(Widget.gpu.content(for: readings, at: start) == .level(.percent(level), isStale: false))
    }
  }

  @Test func memoryPressureIsALevelInWholePercentOrNoneWithoutAValue() {
    let pressure = readings(.memoryPressure, interval: .seconds(5), after: [sample(value(62.4))])
    let unavailable = readings(.memoryPressure, interval: .seconds(5), after: [sample(failed)])

    #expect(Widget.memory.content(for: pressure, at: start) == .level(.percent(62), isStale: false))
    #expect(Widget.memory.content(for: pressure, at: start + .seconds(11)) == .level(.percent(62), isStale: true))
    #expect(Widget.memory.content(for: unavailable, at: start) == .level(.unavailable, isStale: false))
  }

  @Test func failedSampleKeepsShowingTheLastValueUntilItGoesStale() {
    let readings = readings(.gpu, after: [sample(value(40)), sample(failed, at: start + .seconds(2))])

    #expect(Widget.gpu.content(for: readings, at: start + .seconds(4)) == .level(.percent(40), isStale: false))
    #expect(Widget.gpu.content(for: readings, at: start + .seconds(5)) == .level(.percent(40), isStale: true))
  }

  @Test func staleTemperatureKeepsItsValueAndIsMarkedStale() {
    let readings = readings(.temperature, interval: .seconds(10), after: [sample(value(55, .celsius))])

    #expect(Widget.temperature.content(for: readings, at: start + .seconds(20)) == .reading("55°", isStale: false))
    #expect(Widget.temperature.content(for: readings, at: start + .seconds(21)) == .reading("55°", isStale: true))
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

    guard case .graph(let levels, let isStale) = Widget.cpu.content(for: readings, at: start + .seconds(6)) else {
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

    let content = Widget.cpu.content(for: readings, at: start + .seconds(198))

    #expect(content == .graph((40..<100).map(Double.init), isStale: false))
  }

  @Test func readingsAtTheirStaleDeadlineChangeOnlyTheStaleness() throws {
    let levels = Array(repeating: nil, count: 59) + [47.0]

    let contents: [(Widget, MetricUnit, (Bool) -> WidgetContent)] = [
      (.temperature, .celsius, { .reading("47°", isStale: $0) }),
      (.gpu, .percent, { .level(.percent(47), isStale: $0) }),
      (.memory, .percent, { .level(.percent(47), isStale: $0) }),
      (.cpu, .percent, { .graph(levels, isStale: $0) }),
    ]

    for (widget, unit, content) in contents {
      let readings = readings(widget.metric, after: [sample(value(47, unit), at: start)])
      let deadline = try #require(readings.staleAt)

      #expect(widget.content(for: readings, at: deadline - .nanoseconds(1)) == content(false), "\(widget)")
      #expect(widget.content(for: readings, at: deadline) == content(true), "\(widget)")
    }
  }
}
