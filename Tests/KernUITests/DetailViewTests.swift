import AppKit
import Testing

@testable import KernCore
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

func temperature(_ hottest: Double, coolest: Double) -> SampleState {
  .valid(
    MetricValue(hottest, .celsius, temperatures: [PartTemperature(part: .cpu, coolest: coolest, hottest: hottest)]))
}

func usedMemory(_ share: Double, installed: UInt64 = 32 << 30) -> SampleState {
  let used = UInt64(Double(installed) * share / 100)

  return .valid(MetricValue(share, .percent, memory: MemoryAmount(usedBytes: used, installedBytes: installed)))
}

@MainActor
final class DetailViewTests {
  private var windows: [NSWindow] = []

  /// A view outside a window is never drawn, so each view gets an offscreen window.
  func detailView(_ sources: [Metric: MetricSource] = sources) -> DetailView {
    let view = DetailView(sources: sources, chip: "M1 Max")
    let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)

    window.contentView = view
    window.setContentSize(view.fittingSize)
    windows.append(window)
    CATransaction.flush()

    return view
  }

  @Test func showsTheChipThenACardForEachPartOfTheMacThenSettingsAndQuit() throws {
    let view = detailView()

    #expect(view.header.title.stringValue == "Kern")
    #expect(view.header.chip?.stringValue == "M1 Max")
    #expect(view.cards.map(\.heading) == ["CPU", "GPU", "Temperature", "Memory"])
    #expect(view.sections.map(\.metric) == [.cpu, .gpu, .temperature, .memoryPressure, .memory])

    for metric in [Metric.cpu, .gpu, .temperature, .memoryPressure] {
      #expect(view[metric].value != nil && view[metric].history != nil, "\(metric)")
    }

    #expect(view[.memory].value == nil && view[.memory].history == nil)
    #expect(view[.cpu].cores != nil && view[.temperature].sensors != nil)
    #expect(view[.memory].bar != nil && view[.memoryPressure].bar == nil)

    #expect(!view.settingsButton.isEnabled)
    #expect(view.quitButton.isEnabled)
    #expect(view.quitButton.action == #selector(NSApplication.terminate(_:)))
    #expect(view.quitButton.accessibilityLabel() == "Quit Kern")

    let memory = try #require(view.cards.last)

    #expect(view.settingsButton.frame.minY == view.quitButton.frame.minY)
    #expect(view.settingsButton.frame.minY > memory.frame.maxY)
    #expect(view.quitButton.frame.maxX == view.fittingSize.width - DetailStyle().panelPadding)
  }

  @Test func quitShowsNoShortcutItCannotTake() {
    let view = detailView()

    #expect(view.quitButton.title == "Quit")
    #expect(view.quitButton.keyEquivalent == "")
  }

  @Test func enabledButtonFillsMoreUnderThePointerAndDisabledDoesNot() throws {
    let view = detailView()
    let style = DetailStyle()
    let event = try #require(
      NSEvent.enterExitEvent(
        with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        eventNumber: 0, trackingNumber: 0, userData: nil))

    #expect(view.quitButton.trackingAreas.contains { $0.options.contains(.activeAlways) })
    #expect(view.quitButton.fillAlpha == style.cardFillAlpha)

    for button in [view.quitButton, view.settingsButton] {
      button.mouseEntered(with: event)
    }

    #expect(view.quitButton.fillAlpha == style.buttonHoverAlpha)
    #expect(view.settingsButton.fillAlpha == style.cardFillAlpha)

    view.quitButton.mouseExited(with: event)

    #expect(view.quitButton.fillAlpha == style.cardFillAlpha)
  }

  @Test func memoryCardHasPressureLargeWithItsChartThenUsedInGigabytes() throws {
    let view = detailView()

    view.show(readings(.memory, interval: .seconds(5), after: [sample(usedMemory(86.9))]), for: .memory)

    view.show(
      readings(.memoryPressure, interval: .seconds(5), after: [sample(value(61)), sample(value(66))]),
      for: .memoryPressure)

    let card = try #require(view.cards.first { $0.heading == "Memory" })
    let pressure = try #require(view[.memoryPressure].value)
    let chart = try #require(view[.memoryPressure].history)
    let used = try #require(view[.memory].bar)
    let divider = try #require(card.descendants(of: DividerView.self).first)

    #expect(pressure.valueText == "66%")
    #expect(pressure.descendants(of: NSTextField.self).map(\.stringValue).contains("memory pressure"))
    #expect(pressure.accessibilityValue() as? String == "Memory pressure, 66 percent")
    #expect(chart.content?.levels.suffix(2) == [61, 66])
    #expect(chart.content?.span == .seconds(300))
    #expect((used.labelText, used.valueText) == ("Used", "27.8 / 32 GB"))
    #expect(used.accessibilityValue() as? String == "Memory used, 27.8 of 32 gigabytes")
    #expect(used.bar.fill == 0...0.87)
    #expect(used.bar.color.isSame(as: DetailStyle().used))

    for view in [pressure, chart, divider, used] {
      #expect(view.isDescendant(of: card))
    }

    #expect(pressure.frame.maxY < chart.frame.minY)
    #expect(chart.frame.maxY < divider.frame.minY && divider.frame.maxY < used.frame.minY)
  }

  @Test func temperatureCardHasTheHottestSensorLargeAndARangeForEachPart() throws {
    let view = detailView()

    view.show(
      readings(.temperature, interval: .seconds(10), after: [sample(temperature(88.6, coolest: 75.6), at: .now)]),
      for: .temperature)

    let rows = try #require(view[.temperature].sensors?.rows)

    #expect(view[.temperature].value?.valueText == "89°")
    #expect(rows.map(\.labelText) == ["CPU"])
    #expect(rows.map(\.valueText) == ["89°"])
    #expect(abs((rows[0].bar.fill?.lowerBound ?? 0) - 0.756) < 1e-9)
    #expect(abs((rows[0].bar.fill?.upperBound ?? 0) - 0.886) < 1e-9)
    #expect(rows[0].bar.color.isSame(as: DetailStyle().hot))
    #expect(rows[0].accessibilityValue() as? String == "CPU sensors, 76 to 89 degrees Celsius")
  }

  @Test(arguments: [(79.0, "grey"), (80, "orange"), (94.9, "orange"), (95, "red")])
  func sensorRangeIsGreyThenOrangeFromEightyThenRedFromNinetyFive(hottest: Double, color: String) throws {
    let view = detailView()
    let style = DetailStyle()

    view.show(readings(.temperature, after: [sample(temperature(hottest, coolest: 60))]), for: .temperature)

    let expected = ["grey": style.coolBar, "orange": style.hot, "red": style.critical][color]

    #expect(view[.temperature].sensors?.rows.first?.bar.color.isSame(as: expected) == true)
  }

  @Test func temperatureWithoutAValueHasNoSensorRowsAndSaysWhy() throws {
    let view = detailView()

    view.show(readings(.temperature, after: [sample(failed)]), for: .temperature)

    #expect(view[.temperature].sensors?.isHidden == true)
    #expect(view[.temperature].value?.valueText == "—")
    #expect(view[.temperature].value?.statusText == "Unavailable: read failed")
  }

  @Test func voiceOverReadsEachValueWithItsNameUnitAndFreshness() throws {
    let view = detailView()

    view.show(
      readings(.temperature, interval: .seconds(10), after: [sample(value(68.4, .celsius), at: .now)]),
      for: .temperature)

    view.show(
      readings(.memoryPressure, interval: .seconds(5), after: [sample(value(86.4), at: .now - .seconds(60))]),
      for: .memoryPressure
    )

    view.show(
      readings(.memory, interval: .seconds(5), after: [sample(usedMemory(50), at: .now - .seconds(60))]),
      for: .memory
    )

    let value = try #require(view[.temperature].value)

    #expect(value.isAccessibilityElement())
    #expect(value.accessibilityRole() == .staticText)
    #expect(value.accessibilityValue() as? String == "CPU temperature, 68 degrees Celsius")
    #expect(value.accessibilityHelp() == "Hottest of the 10 CPU core sensors in the SMC validated for the M1 Max")
    #expect(value.toolTip == value.accessibilityHelp())
    #expect(value.descendants(of: NSTextField.self).allSatisfy { !$0.isAccessibilityElement() })

    let stale = try #require(view[.memoryPressure].value?.accessibilityValue() as? String)
    let staleUsed = try #require(view[.memory].bar?.accessibilityValue() as? String)

    #expect(stale.hasPrefix("Memory pressure, 86 percent. Stale: not updated since "))
    #expect(staleUsed.hasPrefix("Memory used, 16.0 of 32 gigabytes. Stale: not updated since "))
  }

  @Test func gpuAndTemperatureHeadingsExplainTheirNumberAndTheOthersDoNot() {
    let view = detailView()

    #expect(view[.gpu].info == "Active residency: the share of time it was powered on, not utilization")
    #expect(view[.temperature].info == "Hottest of the 10 CPU core sensors in the SMC validated for the M1 Max")
    #expect(view[.cpu].info == nil && view[.memory].info == nil)
  }

  @Test func temperatureSaysItIsTheHottestSensorBesideItsNumber() throws {
    let view = detailView()
    let value = try #require(view[.temperature].value)
    let texts = value.descendants(of: NSTextField.self).map(\.stringValue)

    #expect(texts.contains("hottest CPU sensor"))
    #expect(
      view[.cpu].value?.descendants(of: NSTextField.self).map(\.stringValue).contains("hottest CPU sensor") == false)
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

  @Test func coresAreOneLinePerformanceOnTheLeftEfficiencyOnTheRight() throws {
    let view = detailView()
    let cores = CoreUtilization(performance: [40, 55.6], efficiency: [80])

    view.show(readings(.cpu, after: [sample(value(60, cores: cores), at: .now)]), for: .cpu)

    let chart = try #require(view[.cpu].cores)
    let style = DetailStyle()

    #expect(chart.groups.map(\.kind) == [.performance, .efficiency])
    #expect(chart.groups.map(\.count) == [2, 1])
    #expect(chart.groups.map(\.shares) == [[40, 55.6], [80]])
    #expect(chart.groups[0].frame.minX == 0)
    #expect(chart.groups[1].frame.maxX == style.contentWidth)
    #expect(chart.frame.height == style.coreTrack.height)

    let tracks = chart.groups[0].trackFrames()

    #expect(tracks.map(\.size) == [style.coreTrack, style.coreTrack])
    #expect(tracks[1].minX - tracks[0].maxX == style.coreSpacing)
  }

  @Test func coresThatDoNotFitOnOneLineWrapWithinTheCard() throws {
    let kinds = Array(repeating: CoreKind.performance, count: 48) + Array(repeating: .efficiency, count: 16)
    let view = detailView(sources.merging([.cpu: source(.utilization, coreKinds: kinds)]) { $1 })
    let chart = try #require(view[.cpu].cores)

    #expect(chart.groups.allSatisfy { $0.frame.width == DetailStyle().contentWidth })
    #expect(chart.groups[0].frame.maxY < chart.groups[1].frame.minY)
    #expect(chart.groups.flatMap { $0.trackFrames() }.allSatisfy { $0.maxX <= DetailStyle().contentWidth })
    #expect(Set(chart.groups[0].trackFrames().map(\.minY)).count > 1)
  }

  @Test func barRowKeepsItsValueAtTheRightAndItsBarBetween() throws {
    let view = detailView()
    let style = DetailStyle()

    view.show(readings(.memory, after: [sample(usedMemory(7), at: .now - .seconds(60))]), for: .memory)

    let row = try #require(view[.memory].bar)
    let texts = row.descendants(of: NSTextField.self)
    let (label, value, status) = (texts[0], texts[1], texts[2])

    #expect(label.frame.minX + label.alignmentRectInsets.left == 0)
    #expect(value.frame.maxX - value.alignmentRectInsets.right == style.contentWidth)
    #expect(row.bar.frame.minX == style.barStart && row.bar.frame.midY == label.frame.midY)
    #expect(row.bar.frame.maxX == style.contentWidth - style.memoryValueWidth - style.valueGap)
    #expect(row.statusText.hasPrefix("Stale: not updated since "))
    #expect(status.frame.minY == label.frame.maxY + style.captionSpacing)
    #expect(row.frame.height == status.frame.maxY)
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
    #expect(view.quitButton.frame.maxY == view.fittingSize.height - DetailStyle().panelPadding)
    #expect(announcements == 1)
  }

  @Test func noValueIsEverBlank() {
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

    for metric in [Metric.cpu, .gpu, .temperature, .memoryPressure] {
      #expect(view[metric].value?.valueText.isEmpty == false, "\(metric)")
      #expect(view[metric].value?.statusText.isEmpty == [.cpu, .memoryPressure].contains(metric), "\(metric)")
    }

    #expect(view[.memory].bar?.valueText == "—")
    #expect(view[.memory].bar?.statusText == "")
    #expect(view[.gpu].value?.statusText == "Unavailable: read failed")
    #expect(view[.temperature].value?.statusText.hasPrefix("Stale: not updated since ") == true)
  }

  @Test func sizeStaysTheSameFromBeforeTheFirstValuesToThem() {
    let cores = CoreUtilization(performance: [40, 55.6], efficiency: [80])
    let view = DetailView(sources: sources)
    let measuring = sample(.unavailable(.noValue(.awaitingBaseline)), at: .now)
    let temperature = sample(temperature(60, coolest: 50), at: .now)
    let before: NSSize

    view.show(readings(.temperature, after: [temperature]), for: .temperature)
    view.show(readings(.cpu, after: [measuring]), for: .cpu)
    view.show(readings(.gpu, after: [measuring]), for: .gpu)
    view.show(readings(.memory, interval: .seconds(5)), for: .memory)
    view.show(readings(.memoryPressure, interval: .seconds(5)), for: .memoryPressure)

    before = view.fittingSize

    view.show(readings(.cpu, after: [measuring, sample(value(60, cores: cores), at: .now)]), for: .cpu)
    view.show(readings(.gpu, after: [measuring, sample(value(9), at: .now)]), for: .gpu)
    view.show(readings(.memory, interval: .seconds(5), after: [sample(usedMemory(71), at: .now)]), for: .memory)
    view.show(
      readings(.memoryPressure, interval: .seconds(5), after: [sample(value(40), at: .now)]), for: .memoryPressure)

    #expect(view.fittingSize == before)
  }

  @Test func historyWithoutValuesDrawsOnlyItsGuide() throws {
    let view = detailView()
    let history = try #require(view[.gpu].history)

    view.show(readings(.gpu, after: [sample(.unavailable(.noValue(.awaitingBaseline)), at: .now)]), for: .gpu)

    let bitmap = rendered(history)
    let guides = HistoryChartView.guideYs(DetailStyle().guideLevels, in: history.bounds)
    let guideY = guides[0]
    let belowGuide = NSRect(x: 0, y: 0, width: history.bounds.width, height: guideY - 1)
    let betweenGuides = NSRect(x: 0, y: guideY + 1, width: history.bounds.width, height: guides[1] - guideY - 2)

    #expect(guides == [22, 43.5])
    #expect(bitmap.ink(in: betweenGuides) == 0)
    #expect(bitmap.ink(in: NSRect(x: 0, y: guides[1] - 0.5, width: history.bounds.width, height: 1)) > 0)

    #expect(history.content?.levels.allSatisfy { $0 == nil } == true)
    #expect(bitmap.ink(in: belowGuide) == 0)
    #expect(bitmap.ink(in: NSRect(x: 0, y: guideY - 0.5, width: history.bounds.width, height: 1)) > 0)
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

  @Test func valueGoesStaleOnTimeWithoutANewSample() async {
    let view = detailView()
    let store = MetricsStore(intervals: [.gpu: .milliseconds(10)])
    var changes = 0

    view[.gpu].changed = { changes += 1 }

    // as `DetailPopover` answers a section that asks at its stale deadline
    view.onStaleDeadline = { [weak view] metric in
      if let readings = store[metric] { view?.show(readings, for: metric) }
    }

    store.record(sample(value(5), at: .now), for: .gpu)
    view.show(store[.gpu]!, for: .gpu)

    #expect(view[.gpu].value?.content?.isStale == false)
    #expect(changes == 1)

    await waitUntil { view[.gpu].value?.content?.isStale == true }

    #expect(view[.gpu].value?.statusText.hasPrefix("Stale: not updated since ") == true)
    #expect(view[.gpu].history?.content?.isStale == true)
    #expect(changes == 2)
  }
}

@MainActor
struct ChartDrawingTests {
  let style = DetailStyle()

  func inWindow<View: NSView>(_ view: View, _ appearance: NSAppearance.Name = .darkAqua) -> View {
    let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)

    window.appearance = NSAppearance(named: appearance)
    window.contentView?.addSubview(view)

    return view
  }

  func levels(_ values: [Int: Double]) -> [Double?] {
    (0..<60).map { values[$0] }
  }

  func slotMiddle(_ slot: Int) -> CGFloat {
    style.contentWidth / 60 * (CGFloat(slot) + 0.5)
  }

  @Test(arguments: [NSAppearance.Name.darkAqua, .aqua])
  func historyGradientSpansTheChartSoBarsMatchAtTheSameHeight(appearance: NSAppearance.Name) {
    let chart = inWindow(HistoryChartView(title: "", fill: .gradient(style.cpuGradient), style: style), appearance)

    chart.show(HistoryChart(levels: levels([10: 100, 20: 20]), span: .seconds(120), unit: .percent, isStale: false))

    let image = rendered(chart)
    let tallLow = image.color(at: NSPoint(x: slotMiddle(10), y: 4))
    let shortLow = image.color(at: NSPoint(x: slotMiddle(20), y: 4))
    let tallHigh = image.color(at: NSPoint(x: slotMiddle(10), y: chart.bounds.height - 1))

    #expect(tallLow.isClose(to: shortLow))
    #expect(!tallLow.isClose(to: tallHigh))

    let top =
      appearance == .darkAqua
      ? NSColor(srgbRed: 0x64 / 255, green: 0xD2 / 255, blue: 0xFF / 255, alpha: 1)
      : NSColor(srgbRed: 0x5A / 255, green: 0xC8 / 255, blue: 0xFA / 255, alpha: 1)

    #expect(tallHigh.isClose(to: top, within: 0.06))
  }

  @Test func temperatureBarsAreOrangeOnlyAboveEightyDegrees() {
    let chart = inWindow(HistoryChartView(title: "", fill: .temperature, style: style))

    chart.show(HistoryChart(levels: levels([10: 85, 20: 80]), span: .seconds(600), unit: .celsius, isStale: false))

    let image = rendered(chart)
    let hot = image.color(at: NSPoint(x: slotMiddle(10), y: 4))
    let cool = image.color(at: NSPoint(x: slotMiddle(20), y: 4))

    #expect(chart.frame.height == style.temperatureHistoryHeight)
    #expect(hot.isClose(to: NSColor(srgbRed: 1, green: 0x9F / 255, blue: 0x0A / 255, alpha: 1), within: 0.06))
    #expect(abs(cool.alphaComponent - 0.26) < 0.03)
    #expect(abs(cool.redComponent - cool.blueComponent) < 0.03)
  }

  @Test func missingSampleLeavesAGapAndZeroStillRises() {
    let chart = inWindow(HistoryChartView(title: "", fill: .gradient(style.gpuGradient), style: style))

    chart.show(HistoryChart(levels: levels([10: 0]), span: .seconds(120), unit: .percent, isStale: false))

    let image = rendered(chart)

    #expect(image.ink(in: NSRect(x: slotMiddle(10) - 0.5, y: 0, width: 1, height: 0.5)) > 0.8)
    #expect(image.ink(in: NSRect(x: slotMiddle(11) - 0.5, y: 0, width: 1, height: 0.5)) == 0)
  }

  @Test func coreFillShowsOnlyTheLowerPartOfTheTrackHighGradient() {
    let group = inWindow(CoreGroupView(kind: .performance, count: 2, width: nil, style: style))

    group.show(shares: [100, 40], isStale: false)

    let image = rendered(group)
    let tracks = group.trackFrames()
    let full = image.color(at: NSPoint(x: tracks[0].midX, y: tracks[0].minY + 3))
    let partial = image.color(at: NSPoint(x: tracks[1].midX, y: tracks[1].minY + 3))
    let above = image.color(at: NSPoint(x: tracks[1].midX, y: tracks[1].minY + 15))

    #expect(full.isClose(to: partial))
    #expect(abs(above.alphaComponent - 0.10) < 0.03)
  }
}

struct HistoryBarTests {
  let box = CGRect(x: 10, y: 0, width: 40, height: 20)

  @Test func eachLevelIsABarSeventyTwoPercentOfItsSlotAndAGapHasNone() {
    let bars = HistoryChartView.bars([50, nil, 100, 0], in: box, share: 0.72, minimumHeight: 1)

    #expect(bars.allSatisfy { abs($0.rect.width - 7.2) < 1e-9 })
    #expect(bars.map(\.rect.midX) == [15, 35, 45])
    #expect(bars.map(\.rect.height) == [10, 20, 1])
    #expect(bars.map(\.level) == [50, 100, 0])
  }

  @Test func levelsAboveTheTopStopAtIt() {
    #expect(HistoryChartView.bars([130], in: box, share: 0.72, minimumHeight: 1).map(\.rect.height) == [20])
  }
}

struct LevelBarTests {
  @Test func levelStartsAtZeroAndIsAtLeastAPixel() {
    #expect(LevelBar.span(of: 0...0.5, in: 100, minimum: 6, pixel: 0.5) == 0...50)
    #expect(LevelBar.span(of: 0...0, in: 100, minimum: 6, pixel: 0.5) == 0...0.5)
  }

  @Test func narrowRangeWidensAroundItsMiddleAndStaysOnTheTrack() {
    #expect(LevelBar.span(of: 0.6...0.8, in: 100, minimum: 6, pixel: 0.5) == 60...80)
    #expect(LevelBar.span(of: 0.7...0.7, in: 100, minimum: 6, pixel: 0.5) == 67...73)
    #expect(LevelBar.span(of: 1...1, in: 100, minimum: 6, pixel: 0.5) == 94...100)
  }
}

@MainActor
func rendered(_ view: NSView) -> NSBitmapImageRep {
  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!

  view.cacheDisplay(in: view.bounds, to: bitmap)

  return bitmap
}

extension NSBitmapImageRep {
  func color(at point: NSPoint) -> NSColor {
    pixels(in: NSRect(x: point.x - 0.25, y: point.y - 0.25, width: 0.5, height: 0.5))[0].usingColorSpace(.sRGB)!
  }
}

extension NSColor {
  /// Whether both resolve to the same colour in light and dark mode.
  func isSame(as other: NSColor?) -> Bool {
    guard let other else { return false }

    return [NSAppearance.Name.aqua, .darkAqua].allSatisfy { name in
      var same = false

      NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
        same = NSColor(cgColor: cgColor)!.isClose(to: NSColor(cgColor: other.cgColor)!, within: 0.001)
      }

      return same
    }
  }

  func isClose(to other: NSColor, within tolerance: CGFloat = 0.02) -> Bool {
    guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return false }

    return abs(a.redComponent - b.redComponent) <= tolerance && abs(a.greenComponent - b.greenComponent) <= tolerance
      && abs(a.blueComponent - b.blueComponent) <= tolerance && abs(a.alphaComponent - b.alphaComponent) <= tolerance
  }
}

extension NSView {
  func descendants<View: NSView>(of type: View.Type) -> [View] {
    subviews.flatMap { ($0 as? View).map { [$0] } ?? [] } + subviews.flatMap { $0.descendants(of: type) }
  }
}
