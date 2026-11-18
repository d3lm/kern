import AppKit
import Testing

@testable import KernCore
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

  /// A view outside a window is never drawn, so each view gets an offscreen window.
  func menuBarView(_ layout: MenuBarLayout = .standard) -> MenuBarView {
    let view = MenuBarView(layout: layout, temperatureUnit: .celsius)
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)

    window.contentView = view

    windows.append(window)

    _ = redraws(of: view)

    return view
  }

  /// The window is never shown, so its views draw only when the flush commits their layers.
  func redraws(of view: MenuBarView) -> [Widget] {
    CATransaction.flush()

    return view.widgetViews.flatMap { widgetView in
      let id = ObjectIdentifier(widgetView)
      let draws = widgetView.drawCount - drawsSeen[id, default: 0]

      drawsSeen[id] = widgetView.drawCount

      return Array(repeating: widgetView.widget, count: draws)
    }
  }

  /// Shows the store's readings as `StatusItemController` does, when told to and again each time a widget asks
  /// at its stale deadline.
  func show(_ metric: Metric, from store: MetricsStore, in view: MenuBarView) {
    view.onStaleDeadline = { [weak view] metric in
      if let readings = store[metric] { view?.show(readings, for: metric) }
    }

    if let readings = store[metric] { view.show(readings, for: metric) }
  }

  @Test func widgetsAppearInTheConfiguredOrderWithoutOverlapping() {
    for widgets in [[Widget.temperature, .cpu, .gpu], [.gpu, .temperature, .cpu], [.cpu]] {
      let view = MenuBarView(layout: MenuBarLayout(widgets: widgets, showsLabels: true)!, temperatureUnit: .celsius)
      let frames = view.widgetViews.map(\.frame)

      #expect(view.widgetViews.map(\.widget) == widgets)
      #expect(view.subviews == view.widgetViews)
      #expect(zip(frames, frames.dropFirst()).allSatisfy { $1.minX - $0.maxX == style.widgetSpacing })
      #expect(frames.first?.minX == 0)
      #expect(frames.last?.maxX == view.intrinsicContentSize.width)
    }
  }

  @Test func layoutWithoutWidgetsShowsKernsSymbolSoTheItemCanStillBeClicked() throws {
    let view = MenuBarView(layout: MenuBarLayout(widgets: [], showsLabels: true)!, temperatureUnit: .celsius)
    let placeholder = try #require(view.placeholder)

    #expect(view.widgetViews.isEmpty)
    #expect(view.subviews == [placeholder])
    #expect(view.intrinsicContentSize.width == placeholder.frame.width)
    #expect(placeholder.frame.width > 10)
    #expect(MenuBarView(layout: .standard, temperatureUnit: .celsius).placeholder == nil)
  }

  @Test func hiddenLabelsNarrowOnlyTheLabelledWidgets() {
    let labelled = MenuBarView(layout: .standard, temperatureUnit: .celsius)

    let unlabelled = MenuBarView(
      layout: MenuBarLayout(widgets: [.temperature, .cpu, .gpu], showsLabels: false)!, temperatureUnit: .celsius)

    func column(_ label: String) -> CGFloat { style.labelWidth(label) + style.labelSpacing }

    #expect(unlabelled[.temperature].frame.width == labelled[.temperature].frame.width)
    #expect(unlabelled[.cpu].frame.width == labelled[.cpu].frame.width - column("CPU"))
    #expect(unlabelled[.gpu].frame.width == labelled[.gpu].frame.width - column("GPU"))
  }

  func gapsBetweenFrames(_ view: MenuBarView) -> [CGFloat] {
    zip(view.widgetViews, view.widgetViews.dropFirst()).map { $1.frame.minX - $0.frame.maxX }
  }

  func distancesFromTrailingEdge(_ view: MenuBarView) -> [CGFloat] {
    view.widgetViews.map { view.intrinsicContentSize.width - $0.frame.maxX }
  }

  @Test(arguments: [[Widget.temperature, .cpu], [.cpu, .temperature], [.gpu, .temperature, .cpu]])
  func temperatureIsAsWideAsItsTextWhereverItIs(widgets: [Widget]) {
    let view = menuBarView(MenuBarLayout(widgets: widgets, showsLabels: true)!)

    for (celsius, text) in [(nil, "—"), (67.0, "67°"), (103.0, "103°")] as [(Double?, String)] {
      let samples = celsius.map { [sample(value($0, .celsius))] } ?? [sample(failed)]

      view.show(readings(.temperature, after: samples), for: .temperature)

      #expect(view[.temperature].frame.width == style.textWidth(text, in: style.valueFont), "\(text)")
      #expect(gapsBetweenFrames(view).allSatisfy { $0 == style.widgetSpacing }, "\(text)")
    }
  }

  @Test(arguments: [[Widget.kern, .cpu], [.cpu, .kern], [.gpu, .kern, .cpu]])
  func kernUsageIsAsWideAsItsWiderLineWhereverItIs(widgets: [Widget]) {
    let view = menuBarView(MenuBarLayout(widgets: widgets, showsLabels: true)!)

    for (state, widest) in [
      (failed, style.textWidth("—", in: style.valueFont)),
      (usage(0.4, megabytes: 18), style.textWidth("18 MB", in: style.stackedFont)),
      (usage(250, megabytes: 7), style.textWidth("250%", in: style.stackedFont)),
    ] {
      view.show(readings(.kern, after: [sample(state)]), for: .kern)

      #expect(view[.kern].frame.width == widest, "\(state)")
      #expect(gapsBetweenFrames(view).allSatisfy { $0 == style.widgetSpacing }, "\(state)")
    }
  }

  /// The menu bar keeps the item's trailing edge in place, so the widgets after a reading never move.
  @Test(arguments: [[Widget.temperature, .cpu, .gpu], [.cpu, .temperature, .gpu], [.gpu, .cpu, .temperature]])
  func readingThatChangesWidthMovesOnlyTheWidgetsBeforeIt(widgets: [Widget]) throws {
    let view = menuBarView(MenuBarLayout(widgets: widgets, showsLabels: true)!)
    let reading = try #require(widgets.firstIndex(of: .temperature))
    let distances = distancesFromTrailingEdge(view)

    for celsius in [nil, 47, 130] as [Double?] {
      let samples = celsius.map { [sample(value($0, .celsius))] } ?? []

      view.show(readings(.temperature, after: samples), for: .temperature)

      #expect(distancesFromTrailingEdge(view)[reading...] == distances[reading...], "\(String(describing: celsius))")
    }
  }

  @Test(arguments: [[Widget.temperature, .cpu, .gpu], [.cpu, .temperature, .gpu], [.gpu, .cpu, .temperature]])
  func chartsAndGaugesMoveNothingThroughTheirWholeRange(widgets: [Widget]) {
    let view = menuBarView(MenuBarLayout(widgets: widgets, showsLabels: true)!)

    view.show(readings(.temperature, after: [sample(value(47, .celsius))]), for: .temperature)

    let frames = view.widgetViews.map(\.frame)

    for percent in [nil, 0, 5, 50, 100] as [Double?] {
      let samples = percent.map { [sample(value($0))] } ?? []

      view.show(readings(.gpu, after: samples), for: .gpu)
      view.show(readings(.cpu, after: samples), for: .cpu)

      #expect(view.widgetViews.map(\.frame) == frames)
    }
  }

  /// Digits are all equally wide, so a reading moves its neighbors only when it gains or loses a digit.
  @Test func readingsThatKeepTheirNumberOfDigitsMoveNothing() {
    let view = menuBarView(MenuBarLayout(widgets: [.cpu, .temperature, .kern, .gpu], showsLabels: true)!)

    view.show(readings(.temperature, after: [sample(value(47, .celsius))]), for: .temperature)
    view.show(readings(.kern, after: [sample(usage(0.4, megabytes: 18))]), for: .kern)

    let frames = view.widgetViews.map(\.frame)

    let changes = [(63.0, usage(3.2, megabytes: 28)), (99, usage(9.9, megabytes: 99)), (10, usage(12, megabytes: 10))]

    for (celsius, kern) in changes {
      view.show(readings(.temperature, after: [sample(value(celsius, .celsius))]), for: .temperature)
      view.show(readings(.kern, after: [sample(kern)]), for: .kern)

      #expect(view.widgetViews.map(\.frame) == frames, "\(celsius)° \(kern)")
    }
  }

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

    view.show(readings(.memoryPressure, after: [sample(value(62))]), for: .memoryPressure)
    #expect(redraws(of: view) == [.memory])
  }

  @Test func kernSampleRedrawsOnlyWhenItsTextChanges() {
    let view = menuBarView(MenuBarLayout(widgets: [.cpu, .kern], showsLabels: true)!)

    view.show(readings(.kern, after: [sample(usage(0.42, megabytes: 18.1))]), for: .kern)
    #expect(redraws(of: view) == [.kern])

    view.show(readings(.kern, after: [sample(usage(0.38, megabytes: 17.9))]), for: .kern)
    #expect(redraws(of: view) == [])

    view.show(readings(.kern, after: [sample(usage(0.5, megabytes: 17.9))]), for: .kern)
    #expect(redraws(of: view) == [.kern])
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

  @Test func valueRedrawsOnceAsStaleWhenNoSuccessfulSampleFollows() async throws {
    let view = menuBarView()
    let store = MetricsStore(intervals: [.gpu: .milliseconds(10)])

    store.record(sample(value(5), at: .now), for: .gpu)
    show(.gpu, from: store, in: view)

    _ = redraws(of: view)

    await waitUntil { view[.gpu].content?.isStale == true }

    #expect(ContinuousClock.now >= (try #require(store[.gpu]?.staleAt)))
    #expect(view[.gpu].content == .level(.percent(5), isStale: true))
    #expect(redraws(of: view) == [.gpu])

    store.record(sample(value(6), at: .now), for: .gpu)
    show(.gpu, from: store, in: view)

    #expect(view[.gpu].content == .level(.percent(6), isStale: false))
  }

  /// At a 250 ms interval a value goes stale 1.5 s after it is acquired, and the check may fire 0.5 s late.
  /// The test checks at 2.1 s, after the first value's latest check and before the second value's deadline.
  @Test func successfulSampleBeforeTheValueGoesStaleKeepsItCurrent() async throws {
    let view = menuBarView()
    let store = MetricsStore(intervals: [.gpu: .milliseconds(250)])
    let first = ContinuousClock.now

    store.record(sample(value(5), at: first), for: .gpu)
    show(.gpu, from: store, in: view)

    try await Task.sleep(until: first + .seconds(1))

    store.record(sample(value(6), at: .now), for: .gpu)
    store.record(sample(failed, at: .now), for: .gpu)
    show(.gpu, from: store, in: view)

    _ = redraws(of: view)

    try await Task.sleep(until: first + .milliseconds(2_100))

    #expect(view[.gpu].content == .level(.percent(6), isStale: false))
    #expect(redraws(of: view) == [])

    await waitUntil { view[.gpu].content?.isStale == true }
  }

  /// At a 10 ms interval the value would go stale 1.02 s after it is acquired. At the 600 ms interval set
  /// meanwhile it goes stale after 2.2 s. The test never looks at a fixed time in between, because a busy
  /// main thread can make it look late.
  @Test func valueWhoseIntervalWasLengthenedGoesStaleAtItsNewDeadlineNotAtItsOldOne() async throws {
    let view = menuBarView()
    let store = MetricsStore(intervals: [.gpu: .milliseconds(10)])
    let acquired = ContinuousClock.now

    store.record(sample(value(5), at: acquired), for: .gpu)
    show(.gpu, from: store, in: view)
    store.setInterval(.milliseconds(600), for: .gpu)

    _ = redraws(of: view)

    await waitUntil { view[.gpu].content?.isStale == true }

    #expect(ContinuousClock.now >= acquired + .milliseconds(2_200))
    #expect(view[.gpu].content == .level(.percent(5), isStale: true))
    #expect(redraws(of: view) == [.gpu])
  }

  @Test func staleCPUChartRedrawsWithTheSameLevels() async {
    let view = menuBarView()
    let store = MetricsStore(intervals: [.cpu: .milliseconds(10)])

    store.record(sample(value(40), at: .now), for: .cpu)
    show(.cpu, from: store, in: view)

    guard case .graph(let levels, isStale: false) = view[.cpu].content else {
      Issue.record("the CPU widget shows a current chart")
      return
    }

    await waitUntil { view[.cpu].content?.isStale == true }

    #expect(view[.cpu].content == .graph(levels, isStale: true))
  }

  @Test func staleChartKeepsTheGapOfAFailedSampleThatArrivedBeforeTheCheck() async {
    let view = menuBarView()
    let store = MetricsStore(intervals: [.cpu: .milliseconds(10)])

    store.record(sample(value(40), at: .now), for: .cpu)
    show(.cpu, from: store, in: view)
    store.record(sample(failed, at: .now), for: .cpu)
    show(.cpu, from: store, in: view)

    await waitUntil { view[.cpu].content?.isStale == true }

    #expect(view[.cpu].content == .graph(Array(repeating: nil, count: 58) + [40, nil], isStale: true))
  }
}

struct ChartSmoothingTests {
  @Test func singleSpikeSpreadsOverItsNeighbors() {
    let smoothed = AreaChart.smoothed([0, 0, 0, 0, 100, 0, 0, 0, 0], radius: 2)

    #expect(smoothed == [0, 0, 20, 20, 20, 20, 20, 0, 0])
  }

  @Test func steadyLevelStaysAsItIs() {
    #expect(AreaChart.smoothed(Array(repeating: 37, count: 60), radius: 2) == Array(repeating: 37, count: 60))
  }

  @Test func gapStaysAGapAndIsNeverAveragedAcross() {
    let smoothed = AreaChart.smoothed([10, 10, nil, 90, 90], radius: 2)

    #expect(smoothed == [10, 10, nil, 90, 90])
  }

  @Test func meanShrinksAtTheEndsOfARun() {
    #expect(AreaChart.smoothed([nil, 10, 20, 60], radius: 2) == [nil, 30, 30, 30])
    #expect(AreaChart.smoothed([12], radius: 2) == [12])
  }

  @Test func zeroStaysALevelSoItIsStillDrawn() {
    #expect(AreaChart.smoothed([nil, 0, nil], radius: 2) == [nil, 0, nil])
  }
}

struct ChartAreaTests {
  let plot = CGRect(x: 10, y: 4, width: 30, height: 14)

  @Test func sixtyLevelsFillThePlotFromEdgeToEdge() {
    let areas = AreaChart.areas(Array(repeating: 50, count: 60), in: plot, pixel: 0.5)

    #expect(areas.count == 1)
    #expect(areas[0].map(\.x).min() == plot.minX)
    #expect(areas[0].map(\.x).max() == plot.maxX)
    #expect(areas[0].allSatisfy { $0.y == plot.minY || $0.y == plot.minY + 7 })
  }

  @Test func gapBreaksTheAreaButZeroRisesOnePixel() {
    let areas = AreaChart.areas([nil, 0, nil, 100], in: plot, pixel: 0.5)

    #expect(areas.count == 2)
    #expect(areas[0].map(\.x).min() == 17.5)
    #expect(areas[0].map(\.x).max() == 25)
    #expect(areas[0].map(\.y).max() == plot.minY + 0.5)
    #expect(areas[1].map(\.x).min() == 32.5)
    #expect(areas[1].map(\.x).max() == 40)
    #expect(areas[1].map(\.y).max() == plot.maxY)
  }

  @Test func lineRunsThroughTheMiddleOfEachSlot() {
    let area = AreaChart.areas([10, 50], in: plot, pixel: 0.5)[0]

    #expect(
      area == [
        CGPoint(x: 10, y: 4), CGPoint(x: 10, y: 5.4),
        CGPoint(x: 17.5, y: 5.4), CGPoint(x: 32.5, y: 11),
        CGPoint(x: 40, y: 11), CGPoint(x: 40, y: 4),
      ])
  }
}
