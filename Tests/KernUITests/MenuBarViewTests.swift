import AppKit
import KernCore
import Testing

@testable import KernUI

extension MenuBarView {
  subscript(widget: Widget) -> WidgetView {
    widgetViews.first { $0.widget == widget }!
  }
}

@MainActor
final class MenuBarViewTests {
  let style = MenuBarStyle()
  private var windows: [NSWindow] = []
  private var drawsSeen: [ObjectIdentifier: Int] = [:]

  /// A view outside a window is never drawn, so each view lives in an offscreen window, as it does in the menu bar.
  func menuBarView(_ layout: MenuBarLayout = .standard) -> MenuBarView {
    let view = MenuBarView(layout: layout)
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)

    window.contentView = view
    windows.append(window)
    _ = redraws(of: view)

    return view
  }

  /// Commits pending drawing as the run loop does, then lists each widget once for every time it was drawn
  /// since the previous call. The window is never shown, so its views draw through their layers, not through
  /// a display pass.
  func redraws(of view: MenuBarView) -> [Widget] {
    CATransaction.flush()

    return view.widgetViews.flatMap { widgetView in
      let id = ObjectIdentifier(widgetView)
      let draws = widgetView.drawCount - drawsSeen[id, default: 0]

      drawsSeen[id] = widgetView.drawCount

      return Array(repeating: widgetView.widget, count: draws)
    }
  }

  @Test func widgetsAppearInTheConfiguredOrderWithoutOverlapping() {
    for widgets in [[Widget.temperature, .cpu, .gpu], [.gpu, .temperature, .cpu], [.cpu]] {
      let view = MenuBarView(layout: MenuBarLayout(widgets: widgets, showsLabels: true)!)
      let frames = view.widgetViews.map(\.frame)

      #expect(view.widgetViews.map(\.widget) == widgets)
      #expect(view.subviews == view.widgetViews)
      #expect(zip(frames, frames.dropFirst()).allSatisfy { $1.minX - $0.maxX == style.widgetSpacing })
      #expect(frames.first?.minX == 0)
      #expect(frames.last?.maxX == view.intrinsicContentSize.width)
    }
  }

  @Test func hiddenLabelsNarrowOnlyTheLabelledWidgets() {
    let labelled = MenuBarView(layout: .standard)
    let unlabelled = MenuBarView(layout: MenuBarLayout(widgets: [.temperature, .cpu, .gpu], showsLabels: false)!)

    func column(_ label: String) -> CGFloat { style.labelWidth(label) + style.labelSpacing }

    #expect(unlabelled[.temperature].frame.width == labelled[.temperature].frame.width)
    #expect(unlabelled[.cpu].frame.width == labelled[.cpu].frame.width - column("CPU"))
    #expect(unlabelled[.gpu].frame.width == labelled[.gpu].frame.width - column("GPU"))
  }

  @Test func everyTemperatureFitsTheWidthReservedForIt() {
    let texts = (0...999).map { WidgetContent.text(for: MetricValue(Double($0), .celsius)) }
    let widest = (texts + [WidgetContent.unavailableText]).map { style.textWidth($0, in: style.valueFont) }.max()!

    #expect(widest <= style.valueWidth(of: .temperature))
  }

  /// The menu bar keeps an item's trailing edge in place, so a widget stays put on screen exactly when
  /// the distance from its trailing edge to the item's does not change. The leading widget grows and
  /// shrinks at its other edge.
  func distancesFromTrailingEdge(_ view: MenuBarView) -> [CGFloat] {
    view.widgetViews.map { view.intrinsicContentSize.width - $0.frame.maxX }
  }

  @Test(arguments: [[Widget.temperature, .cpu, .gpu], [.cpu, .temperature, .gpu], [.gpu, .cpu, .temperature]])
  func neighborsKeepTheirPlaceWhileValuesMoveThroughTheirWholeRange(widgets: [Widget]) {
    let view = menuBarView(MenuBarLayout(widgets: widgets, showsLabels: true)!)
    let distances = distancesFromTrailingEdge(view)

    for celsius in [nil, 5, 47, 130] as [Double?] {
      let samples = celsius.map { [sample(value($0, .celsius))] } ?? []

      view.show(readings(.temperature, after: samples), for: .temperature)

      #expect(distancesFromTrailingEdge(view) == distances)
    }

    for percent in [nil, 0, 5, 50, 100] as [Double?] {
      let samples = percent.map { [sample(value($0))] } ?? []

      view.show(readings(.gpu, after: samples), for: .gpu)
      view.show(readings(.cpu, after: samples), for: .cpu)

      #expect(distancesFromTrailingEdge(view) == distances)
    }
  }

  @Test func leadingTemperatureIsAsWideAsItsTextSoTheItemHasEvenMargins() {
    let view = menuBarView()

    for (celsius, text) in [(nil, "—"), (67.0, "67°"), (103.0, "103°")] as [(Double?, String)] {
      let samples = celsius.map { [sample(value($0, .celsius))] } ?? [sample(failed)]

      view.show(readings(.temperature, after: samples), for: .temperature)

      #expect(view[.temperature].frame.width == style.textWidth(text, in: style.valueFont), "\(text)")
      #expect(view[.cpu].frame.minX == view[.temperature].frame.maxX + style.widgetSpacing, "\(text)")
    }
  }

  @Test func temperatureAfterAnotherWidgetKeepsRoomForThreeDigits() {
    let view = menuBarView(MenuBarLayout(widgets: [.cpu, .temperature], showsLabels: true)!)

    view.show(readings(.temperature, after: [sample(value(67, .celsius))]), for: .temperature)

    #expect(view[.temperature].frame.width == style.valueWidth(of: .temperature))
  }

  /// The temperature starts with two digits, so the sample that changes it keeps the leading widget's width.
  @Test func sampleRedrawsOnlyTheWidgetOfItsMetric() {
    let view = menuBarView()

    view.show(readings(.temperature, after: [sample(value(46, .celsius))]), for: .temperature)
    _ = redraws(of: view)

    view.show(readings(.cpu, after: [sample(value(30))]), for: .cpu)
    #expect(redraws(of: view) == [.cpu])

    view.show(readings(.gpu, after: [sample(value(5))]), for: .gpu)
    #expect(redraws(of: view) == [.gpu])

    view.show(readings(.temperature, after: [sample(value(47, .celsius))]), for: .temperature)
    #expect(redraws(of: view) == [.temperature])

    view.show(readings(.memory, after: [sample(value(62))]), for: .memory)
    #expect(redraws(of: view) == [.memory])
  }

  @Test func everyCPUSampleRedrawsTheChartOnce() {
    let view = menuBarView()
    var samples: [MetricSample] = []
    var draws: [[Widget]] = []

    for index in 0..<100 {
      samples.append(sample(index.isMultiple(of: 7) ? failed : value(Double(index)), at: .now))

      view.show(readings(.cpu, after: samples), for: .cpu)
      draws.append(redraws(of: view))
    }

    #expect(draws == Array(repeating: [.cpu], count: 100))
  }

  @Test func sampleThatChangesNothingVisibleDoesNotRedraw() {
    let view = menuBarView()

    view.show(readings(.gpu, after: [sample(value(5.2), at: .now)]), for: .gpu)
    _ = redraws(of: view)

    view.show(readings(.gpu, after: [sample(value(4.9), at: .now)]), for: .gpu)
    #expect(redraws(of: view) == [])

    view.show(readings(.gpu, after: [sample(value(5.2), at: .now), sample(failed, at: .now)]), for: .gpu)
    #expect(redraws(of: view) == [])
  }

  @Test func nothingRedrawsBetweenSamples() async throws {
    let view = menuBarView()

    view.show(readings(.cpu, after: [sample(value(30), at: .now)]), for: .cpu)
    view.show(readings(.gpu, after: [sample(value(5), at: .now)]), for: .gpu)
    view.show(
      readings(.temperature, interval: .seconds(10), after: [sample(value(47, .celsius), at: .now)]), for: .temperature)
    _ = redraws(of: view)

    try await Task.sleep(for: .seconds(2))

    #expect(redraws(of: view) == [])
  }

  @Test func valueRedrawsOnceAsStaleWhenNoSuccessfulSampleFollows() async {
    let view = menuBarView()
    let gpu = readings(.gpu, interval: .milliseconds(10), after: [sample(value(5), at: .now)])

    view.show(gpu, for: .gpu)
    _ = redraws(of: view)

    await waitUntil { view[.gpu].content?.isStale == true }

    #expect(ContinuousClock.now >= gpu.staleAt!)
    #expect(view[.gpu].content == .level(5, isStale: true))
    #expect(redraws(of: view) == [.gpu])

    view.show(readings(.gpu, interval: .milliseconds(10), after: [sample(value(6), at: .now)]), for: .gpu)

    #expect(view[.gpu].content == .level(6, isStale: false))
  }

  /// With a 250 ms interval a value goes stale 1.5 s after it was acquired, and the check may fire
  /// up to 0.5 s late. The test looks between the first value's latest possible check and the second
  /// value's deadline.
  @Test func successfulSampleBeforeTheValueGoesStaleKeepsItCurrent() async throws {
    let view = menuBarView()
    let first = ContinuousClock.now

    view.show(readings(.gpu, interval: .milliseconds(250), after: [sample(value(5), at: first)]), for: .gpu)

    try await Task.sleep(until: first + .seconds(1))

    let failedSince = [sample(value(6), at: .now), sample(failed, at: .now)]

    view.show(readings(.gpu, interval: .milliseconds(250), after: failedSince), for: .gpu)
    _ = redraws(of: view)

    try await Task.sleep(until: first + .milliseconds(2_100))

    #expect(view[.gpu].content == .level(6, isStale: false))
    #expect(redraws(of: view) == [])

    await waitUntil { view[.gpu].content?.isStale == true }
  }

  /// Blocking the main thread past the deadline makes the check wake up and queue behind the main thread.
  /// Yielding then delivers the next sample after the check has woken, when cancelling it no longer stops it,
  /// but before it runs.
  @Test func sampleArrivingAfterTheStaleCheckWokeKeepsItsValueCurrent() async throws {
    let view = menuBarView()

    view.show(readings(.gpu, interval: .milliseconds(10), after: [sample(value(5), at: .now)]), for: .gpu)

    usleep(1_800_000)
    await Task.yield()

    view.show(readings(.gpu, interval: .milliseconds(10), after: [sample(value(6), at: .now)]), for: .gpu)

    try await Task.sleep(for: .milliseconds(200))

    #expect(view[.gpu].content == .level(6, isStale: false))

    await waitUntil { view[.gpu].content?.isStale == true }
  }

  @Test func staleCPUChartRedrawsWithTheSameLevels() async {
    let view = menuBarView()
    let cpu = readings(.cpu, interval: .milliseconds(10), after: [sample(value(40), at: .now)])

    view.show(cpu, for: .cpu)

    guard case .graph(let levels, isStale: false) = view[.cpu].content else {
      Issue.record("the CPU widget shows a current chart")
      return
    }

    await waitUntil { view[.cpu].content?.isStale == true }

    #expect(view[.cpu].content == .graph(levels, isStale: true))
  }
}

struct ChartSmoothingTests {
  @Test func singleSpikeSpreadsOverItsNeighbors() {
    let smoothed = WidgetView.smoothed([0, 0, 0, 0, 100, 0, 0, 0, 0], radius: 2)

    #expect(smoothed == [0, 0, 20, 20, 20, 20, 20, 0, 0])
  }

  @Test func steadyLevelStaysAsItIs() {
    #expect(WidgetView.smoothed(Array(repeating: 37, count: 60), radius: 2) == Array(repeating: 37, count: 60))
  }

  @Test func gapStaysAGapAndIsNeverAveragedAcross() {
    let smoothed = WidgetView.smoothed([10, 10, nil, 90, 90], radius: 2)

    #expect(smoothed == [10, 10, nil, 90, 90])
  }

  @Test func meanShrinksAtTheEndsOfARun() {
    #expect(WidgetView.smoothed([nil, 10, 20, 60], radius: 2) == [nil, 30, 30, 30])
    #expect(WidgetView.smoothed([12], radius: 2) == [12])
  }

  @Test func zeroStaysALevelSoItIsStillDrawn() {
    #expect(WidgetView.smoothed([nil, 0, nil], radius: 2) == [nil, 0, nil])
  }
}

struct ChartAreaTests {
  let plot = CGRect(x: 10, y: 4, width: 30, height: 14)

  @Test func sixtyLevelsFillThePlotFromEdgeToEdge() {
    let areas = WidgetView.areas(Array(repeating: 50, count: 60), in: plot, pixel: 0.5)

    #expect(areas.count == 1)
    #expect(areas[0].map(\.x).min() == plot.minX)
    #expect(areas[0].map(\.x).max() == plot.maxX)
    #expect(areas[0].allSatisfy { $0.y == plot.minY || $0.y == plot.minY + 7 })
  }

  @Test func gapBreaksTheAreaButZeroRisesOnePixel() {
    let areas = WidgetView.areas([nil, 0, nil, 100], in: plot, pixel: 0.5)

    #expect(areas.count == 2)
    #expect(areas[0].map(\.x).min() == 17.5)
    #expect(areas[0].map(\.x).max() == 25)
    #expect(areas[0].map(\.y).max() == plot.minY + 0.5)
    #expect(areas[1].map(\.x).min() == 32.5)
    #expect(areas[1].map(\.x).max() == 40)
    #expect(areas[1].map(\.y).max() == plot.maxY)
  }

  @Test func lineRunsThroughTheMiddleOfEachSlot() {
    let area = WidgetView.areas([10, 50], in: plot, pixel: 0.5)[0]

    #expect(
      area == [
        CGPoint(x: 10, y: 4), CGPoint(x: 10, y: 5.4),
        CGPoint(x: 17.5, y: 5.4), CGPoint(x: 32.5, y: 11),
        CGPoint(x: 40, y: 11), CGPoint(x: 40, y: 4),
      ])
  }
}
