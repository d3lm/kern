import AppKit
import KernCore
import Testing

@testable import KernUI

let sources: [Metric: MetricSource] = [
  .cpu: source(.utilization, coreKinds: [.performance, .performance, .efficiency]),
  .gpu: source(.activeResidency),
  .temperature: source(.temperature, "Hottest of the 10 CPU core sensors in the SMC validated for the M1 Max"),
  .memory: source(.memoryUsage),
  .memoryPressure: source(.memoryPressure),
]

extension DetailView {
  subscript(metric: Metric) -> DetailSection {
    sections.first { $0.metric == metric }!
  }
}

@MainActor
final class DetailViewTests {
  private var windows: [NSWindow] = []

  /// A view outside a window is never drawn, so each view gets an offscreen window.
  func detailView() -> DetailView {
    let view = DetailView(sources: sources)
    let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)

    window.contentView = view
    window.setContentSize(view.fittingSize)
    windows.append(window)
    CATransaction.flush()

    return view
  }

  @Test func showsACardForEachPartOfTheMacWithItsChartsAndNoButtons() {
    let view = detailView()

    #expect(view.cards.map(\.heading) == ["CPU", "CPU Cores", "GPU", "Temperature", "Memory"])
    #expect(view.sections.map(\.metric) == [.cpu, .gpu, .temperature, .memory, .memoryPressure])
    #expect(view[.cpu].history != nil && view[.cpu].cores != nil)
    #expect(view[.gpu].history != nil && view[.gpu].cores == nil)

    for metric in [Metric.temperature, .memory, .memoryPressure] {
      #expect(view[metric].history == nil && view[metric].cores == nil, "\(metric)")
    }

    #expect(view.descendants(of: NSButton.self).isEmpty)
  }

  @Test func usedMemoryAndMemoryPressureAreTwoSeparatelyLabelledValuesInOneCard() {
    let view = detailView()

    view.show(readings(.memory, interval: .seconds(5), after: [sample(value(86.4))]), for: .memory)
    view.show(readings(.memoryPressure, interval: .seconds(5), after: [sample(value(66))]), for: .memoryPressure)

    let memory = view.cards.first { $0.heading == "Memory" }

    #expect((view[.memory].rows[0].labelText, view[.memory].rows[0].valueText) == ("Used", "86%"))
    #expect((view[.memoryPressure].rows[0].labelText, view[.memoryPressure].rows[0].valueText) == ("Pressure", "66%"))
    #expect(view[.memory].rows[0].isDescendant(of: memory!) && view[.memoryPressure].rows[0].isDescendant(of: memory!))
  }

  @Test func voiceOverReadsEachValueWithItsNameUnitAndFreshness() throws {
    let view = detailView()

    view.show(
      readings(.temperature, interval: .seconds(10), after: [sample(value(68.4, .celsius), at: .now)]),
      for: .temperature)

    view.show(
      readings(.memory, interval: .seconds(5), after: [sample(value(86.4), at: .now - .seconds(60))]),
      for: .memory
    )

    let row = view[.temperature].rows[0]

    #expect(row.isAccessibilityElement())
    #expect(row.accessibilityRole() == .staticText)
    #expect(row.accessibilityValue() as? String == "CPU temperature, 68 degrees Celsius")
    #expect(row.accessibilityHelp() == "Hottest of the 10 CPU core sensors in the SMC validated for the M1 Max")
    #expect(row.toolTip == row.accessibilityHelp())
    #expect(row.descendants(of: NSTextField.self).allSatisfy { !$0.isAccessibilityElement() })

    let stale = try #require(view[.memory].rows[0].accessibilityValue() as? String)

    #expect(stale.hasPrefix("Memory used, 86 percent. Stale: not updated since "))
  }

  @Test func cpuCardHasUsageUserAndSystemLines() throws {
    let view = detailView()
    let split = CPUTimeSplit(user: 17.6, system: 24.4)

    view.show(readings(.cpu, after: [sample(.valid(MetricValue(42, .percent, split: split)), at: .now)]), for: .cpu)

    let card = try #require(view.cards.first { $0.heading == "CPU" })
    let rows = view[.cpu].rows

    #expect(rows.map(\.labelText) == ["Usage", "User", "System"])
    #expect(rows.map(\.valueText) == ["42%", "18%", "24%"])
    #expect(rows.allSatisfy { $0.isDescendant(of: card) })
    #expect(zip(rows, rows.dropFirst()).allSatisfy { $0.frame.maxY < $1.frame.minY })
  }

  @Test func chartsDescribeThemselvesToVoiceOver() {
    let view = detailView()
    let cores = CoreUtilization(performance: [40], efficiency: [80])

    view.show(readings(.cpu, after: [sample(value(60, cores: cores), at: .now)]), for: .cpu)

    #expect(view[.cpu].history?.accessibilityRole() == .image)

    #expect(
      view[.cpu].history?.accessibilityLabel()
        == "CPU usage history. Last 2 minutes: lowest 60 percent, highest 60 percent")

    #expect(
      view[.cpu].cores?.accessibilityLabel()
        == "CPU usage per core. Performance cores: 40 percent. Efficiency cores: 80 percent")
  }

  @Test func perCoreChartHasALineForEachCoreWithItsNameAndShare() throws {
    let view = detailView()
    let cores = CoreUtilization(performance: [40, 55.6], efficiency: [80])

    view.show(readings(.cpu, after: [sample(value(60, cores: cores), at: .now)]), for: .cpu)

    let chart = try #require(view[.cpu].cores)
    let lines = chart.descendants(of: CoreRowView.self)

    #expect(lines.map(\.name) == ["P-Core #1", "P-Core #2", "E-Core #1"])
    #expect(lines.map(\.bar.value?.amount) == [40, 56, 80])
    #expect(lines.map { chart.bounds.height - $0.frame.maxY } == [0, 18, 44])
    #expect(chart.frame.height == 62)
  }

  @Test func lineKeepsItsValueAndBarInColumnsAndOnlyAStatusBelow() {
    let view = detailView()
    let style = DetailStyle()

    view.show(
      readings(.temperature, interval: .seconds(10), after: [sample(value(68.4, .celsius), at: .now)]),
      for: .temperature)

    view.show(
      readings(.memory, interval: .seconds(5), after: [sample(value(7), at: .now - .seconds(60))]),
      for: .memory
    )

    for metric in [Metric.temperature, .memory] {
      let line = view[metric].rows[0]
      let texts = line.descendants(of: NSTextField.self)
      let (label, value, status) = (texts[0], texts[1], texts[2])
      let bar = line.descendants(of: LevelBar.self)[0]

      #expect(texts.count == 3, "\(metric)")
      #expect(label.frame.minX + label.alignmentRectInsets.left == 0, "\(metric)")
      #expect(value.frame.maxX - value.alignmentRectInsets.right == style.valueEnd, "\(metric)")
      #expect(bar.frame.minX == style.contentWidth - style.barWidth && bar.frame.midY == label.frame.midY, "\(metric)")
      #expect(status.isHidden == (metric == .temperature), "\(metric)")

      if metric == .temperature {
        #expect(line.frame.height == label.frame.maxY)
      } else {
        #expect(status.frame.minY == label.frame.maxY + style.captionSpacing)
        #expect(line.frame.height == status.frame.maxY)
      }
    }
  }

  @Test func cardsBelowAndTheFittingSizeFollowACardThatGrows() throws {
    let view = detailView()
    let failedFirst = readings(.cpu, after: [sample(failed, at: .now)])

    view.show(readings(.cpu, after: [sample(.unavailable(.noValue(.awaitingBaseline)), at: .now)]), for: .cpu)

    let gpu = try #require(view.cards.first { $0.heading == "GPU" })
    let before = (size: view.fittingSize, gpuTop: gpu.frame.minY)
    var announcements = 0

    view.fittingSizeChanged = { announcements += 1 }
    view.show(failedFirst, for: .cpu)
    view.show(failedFirst, for: .cpu)

    let growth = view.fittingSize.height - before.size.height

    #expect(growth > 0)
    #expect(view.fittingSize.width == before.size.width)
    #expect(gpu.frame.minY == before.gpuTop + growth)
    #expect(announcements == 1)
  }

  @Test func noRowIsEverBlank() {
    let view = detailView()

    view.show(readings(.cpu, after: [sample(.unavailable(.noValue(.awaitingBaseline)))]), for: .cpu)
    view.show(readings(.gpu, after: [sample(failed)]), for: .gpu)

    view.show(
      readings(.temperature, interval: .seconds(10), after: [sample(value(50, .celsius), at: .now - .seconds(60))]),
      for: .temperature)

    view.show(readings(.memory, interval: .seconds(5)), for: .memory)

    view.show(
      readings(.memoryPressure, interval: .seconds(5), after: [sample(value(66), at: .now)]),
      for: .memoryPressure
    )

    for section in view.sections {
      #expect(!section.rows[0].valueText.isEmpty, "\(section.metric)")

      #expect(
        section.rows[0].statusText.isEmpty == [.memoryPressure, .cpu, .memory].contains(section.metric),
        "\(section.metric)")
    }

    #expect(view[.gpu].rows[0].statusText == "Unavailable: read failed")
    #expect(view[.temperature].rows[0].statusText.hasPrefix("Stale: not updated since "))
  }

  @Test func sizeStaysTheSameFromBeforeTheFirstValuesToThem() {
    let cores = CoreUtilization(performance: [40, 55.6], efficiency: [80])

    let view = DetailView(
      sources: sources.merging(
        [.cpu: source(.utilization, coreKinds: [.efficiency, .performance, .performance])]
      ) {
        $1
      }
    )

    let measuring = sample(.unavailable(.noValue(.awaitingBaseline)), at: .now)
    let before: NSSize

    view.show(readings(.cpu, after: [measuring]), for: .cpu)
    view.show(readings(.gpu, after: [measuring]), for: .gpu)
    view.show(readings(.memory, interval: .seconds(5)), for: .memory)
    before = view.fittingSize

    view.show(readings(.cpu, after: [measuring, sample(value(60, cores: cores), at: .now)]), for: .cpu)
    view.show(readings(.gpu, after: [measuring, sample(value(9), at: .now)]), for: .gpu)
    view.show(readings(.memory, interval: .seconds(5), after: [sample(value(71), at: .now)]), for: .memory)

    #expect(view.fittingSize == before)
    #expect(view[.cpu].cores?.descendants(of: CoreRowView.self).count == 3)
  }

  @Test func historyWithoutValuesDrawsNothing() throws {
    let view = detailView()
    let history = try #require(view[.gpu].history)

    view.show(readings(.gpu, after: [sample(.unavailable(.noValue(.awaitingBaseline)), at: .now)]), for: .gpu)

    let bitmap = try #require(history.bitmapImageRepForCachingDisplay(in: history.bounds))

    history.cacheDisplay(in: history.bounds, to: bitmap)

    #expect(history.content?.levels.allSatisfy { $0 == nil } == true)
    #expect(bitmap.ink(in: history.bounds) == 0)
  }

  @Test func chartsRedrawOnlyWhenASampleChangesThem() throws {
    let view = detailView()
    let history = try #require(view[.cpu].history)
    let cpu = readings(.cpu, after: [sample(value(30), at: .now)])

    view.show(cpu, for: .cpu)

    CATransaction.flush()

    let draws = history.drawCount

    view.show(cpu, for: .cpu)
    view.show(readings(.gpu, after: [sample(value(5), at: .now)]), for: .gpu)

    CATransaction.flush()

    #expect(history.drawCount == draws)

    view.show(readings(.cpu, after: [sample(value(30), at: .now), sample(value(31), at: .now)]), for: .cpu)

    CATransaction.flush()

    #expect(history.drawCount == draws + 1)
  }

  @Test func rowGoesStaleOnTimeWithoutANewSample() async {
    let view = detailView()
    var changes = 0

    view[.gpu].changed = { changes += 1 }
    view.show(readings(.gpu, interval: .milliseconds(10), after: [sample(value(5), at: .now)]), for: .gpu)

    #expect(view[.gpu].rows[0].content?.isStale == false)
    #expect(changes == 1)

    await waitUntil { view[.gpu].rows[0].content?.isStale == true }

    #expect(view[.gpu].rows[0].statusText.hasPrefix("Stale: not updated since "))
    #expect(view[.gpu].history?.content?.isStale == true)
    #expect(changes == 2)
  }
}

struct CoreRowTests {
  @Test func performanceCoresComeFirstThenAGapThenTheEfficiencyCores() {
    let tops = CoreChartView.rowTops(sizes: [3, 2], rowHeight: 18, groupSpacing: 8)

    #expect(tops == [[0, 18, 36], [62, 80]])
    #expect(CoreChartView.height(sizes: [3, 2], rowHeight: 18, groupSpacing: 8) == 98)
  }

  @Test func emptyGroupLeavesNoGap() {
    #expect(CoreChartView.rowTops(sizes: [4, 0], rowHeight: 18, groupSpacing: 8) == [[0, 18, 36, 54]])
  }

  @Test func withoutCoresTheChartKeepsRoomForOneLine() {
    #expect(CoreChartView.height(sizes: [], rowHeight: 18, groupSpacing: 8) == 18)
  }
}

struct HistoryBarTests {
  let box = CGRect(x: 10, y: 0, width: 40, height: 20)

  @Test func eachLevelIsABarInItsSlotAndAGapHasNone() {
    let bars = HistoryChartView.bars([50, nil, 100, 0], in: box, spacing: 1, pixel: 0.5)

    #expect(bars.map(\.minX) == [10, 30, 40])
    #expect(bars.map(\.width) == [9, 9, 9])
    #expect(bars.map(\.height) == [10, 20, 0.5])
  }
}

extension NSView {
  func descendants<View: NSView>(of type: View.Type) -> [View] {
    subviews.flatMap { ($0 as? View).map { [$0] } ?? [] } + subviews.flatMap { $0.descendants(of: type) }
  }
}
