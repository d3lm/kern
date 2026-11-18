import AppKit
import Testing

@testable import KernCore
@testable import KernUI

extension AppEvents {
  @MainActor
  final class DetailPopoverTests {
    let calls: [Metric: SensorCalls] = Dictionary(uniqueKeysWithValues: Metric.allCases.map { ($0, SensorCalls()) })
    let coordinator: MetricsCoordinator<ContinuousClock>
    let details: DetailPopover
    let menuBarView = MenuBarView(layout: .standard, temperatureUnit: .celsius)
    let button = NSButton(title: "", target: nil, action: nil)

    /// Off every screen, so the popover never appears in front of the person running the tests.
    let window = NSWindow(
      contentRect: NSRect(x: -20_000, y: -20_000, width: 200, height: 22),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )

    init() {
      let calls = calls

      coordinator = MetricsCoordinator(
        providers: Dictionary(
          uniqueKeysWithValues: Metric.allCases.map { metric in
            (metric, MetricProvider(sensor: sensor(for: metric, calls: calls[metric]!)))
          }
        )
      )

      details = DetailPopover(
        coordinator: coordinator, chip: .recognized(Chip(family: .m1, variant: .max)), temperatureUnit: .celsius)

      button.frame = NSRect(x: 0, y: 0, width: 200, height: 22)

      button.addSubview(menuBarView)

      window.contentView = button

      window.orderFrontRegardless()

      coordinator.start()
    }

    func reads(of metric: Metric) -> Int {
      calls[metric]!.all.count { $0 == "read" }
    }

    @Test func openingSamplesUsedMemoryAndClosingStopsIt() async throws {
      await waitUntil { reads(of: .cpu) == 1 }

      #expect(calls[.memory]!.all.isEmpty)

      details.toggle(from: button)

      #expect(details.isShown)
      #expect(coordinator.areDetailsVisible)

      await waitUntil { details.content?[.memory].bar?.valueText == "12%" }

      details.toggle(from: button)

      #expect(!details.isShown)
      #expect(!coordinator.areDetailsVisible)

      await waitUntil { calls[.memory]!.all.last == "close" }

      #expect(calls[.memory]!.all == ["open", "read", "close"])
    }

    @Test func headerNamesTheChip() {
      details.toggle(from: button)

      #expect(details.content?.header.chip?.stringValue == "M1 Max")
    }

    @Test func panelOpensCenteredBelowTheItem() throws {
      details.toggle(from: button)

      let panel = try #require(details.content?.window)
      let item = window.frame

      #expect(panel.frame.maxY == item.minY - DetailStyle().panelGap)
      #expect(panel.frame.midX == item.midX)
      #expect(panel.frame.size == details.content?.fittingSize)
    }

    @Test func panelFollowsItsContentAndKeepsItsTopUnderTheItem() throws {
      details.toggle(from: button)

      let panel = try #require(details.content?.window)
      let before = panel.frame

      coordinator.store.record(sample(value(60), at: .now - .seconds(60)), for: .cpu)

      #expect(panel.frame.height > before.height)
      #expect(panel.frame.size == details.content?.fittingSize)
      #expect(panel.frame.maxY == before.maxY)
    }

    @Test func panelIsDrawnBeforeOpeningReturns() throws {
      details.toggle(from: button)

      let content = try #require(details.content)

      #expect(content[.cpu].history?.drawCount == 1)
      #expect(content[.gpu].history?.drawCount == 1)
    }

    @Test func itemStaysHighlightedWhileThePanelIsOpen() async {
      details.toggle(from: button)

      await waitUntil { button.isHighlighted }

      details.toggle(from: button)

      #expect(!button.isHighlighted)
    }

    @Test func openPopoverShowsEveryNewSample() async throws {
      details.toggle(from: button)

      let content = try #require(details.content)

      coordinator.store.record(sample(value(77), at: .now), for: .gpu)

      #expect(content[.gpu].value?.valueText == "77%")
    }

    /// At a 100 ms interval a value goes stale 1.2 s after it is acquired, and the check may fire 0.5 s late,
    /// so the test looks 2 s after the last sample. No sample is in flight once the sensor has closed.
    @Test func valueWhoseIntervalWasLengthenedStaysCurrentPastItsOldStaleDeadline() async throws {
      coordinator.setInterval(.milliseconds(100), for: .gpu)
      details.toggle(from: button)

      await waitUntil { details.content?[.gpu].value?.valueText == "12%" }

      coordinator.stop()

      await waitUntil { calls[.gpu]!.all.last == "close" }

      let stopped = ContinuousClock.now

      coordinator.setInterval(.seconds(60), for: .gpu)

      try await Task.sleep(until: stopped + .seconds(2))

      #expect(coordinator.store[.gpu]?.isStale(at: .now) == false)
      #expect(details.content?[.gpu].value?.content?.isStale == false)
      #expect(details.content?[.gpu].history?.content?.isStale == false)
    }

    @Test func closingReleasesTheWindowAndViewsAndStopsFollowingSamples() async throws {
      weak var content: DetailView?
      weak var popoverWindow: NSWindow?

      details.toggle(from: button)

      content = details.content
      popoverWindow = content?.window

      let row = try #require(content?[.gpu].value)

      #expect(popoverWindow?.isVisible == true)

      details.toggle(from: button)
      coordinator.store.record(sample(value(77), at: .now), for: .gpu)

      #expect(details.content == nil)
      #expect(row.valueText != "77%")

      await waitUntil { content == nil && popoverWindow == nil }
    }

    @Test func twentyOpeningsLeaveNoViewsBehind() async {
      var opened: [() -> DetailView?] = []

      for _ in 0..<20 {
        details.toggle(from: button)

        weak var content = details.content

        opened.append { content }
        details.toggle(from: button)
      }

      await waitUntil { opened.allSatisfy { $0() == nil } }
    }

    @Test func noViewOfThePanelIsLargeEnoughForAppKitToDrawItWithMetal() throws {
      details.toggle(from: button)

      let cores = CoreUtilization(
        performance: Array(repeating: 40, count: 48),
        efficiency: Array(repeating: 80, count: 16)
      )

      let panel = try #require(details.content?.window)

      coordinator.store.record(sample(value(60, cores: cores), at: .now), for: .cpu)
      CATransaction.flush()

      let layers = try #require(panel.contentView?.layer).withDescendants

      #expect(layers.contains { $0.contents != nil })
      #expect(layers.filter(\.drawsAsynchronously).map(\.bounds.size) == [])
    }

    @Test func panelIsLaidOutByFramesAlone() throws {
      details.toggle(from: button)

      let root = try #require(details.content?.window?.contentView)
      let constraints = ([root] + root.descendants(of: NSView.self)).flatMap(\.constraints)

      #expect(constraints.filter { $0.className != "NSAutoresizingMaskLayoutConstraint" } == [])
    }

    @Test(arguments: [
      (NSEvent.EventType.rightMouseDown, NSEvent.ModifierFlags(), true),
      (.leftMouseDown, .control, true),
      (.leftMouseDown, NSEvent.ModifierFlags(), false),
      (.leftMouseDown, .option, false),
    ])
    func rightClickOrControlClickOpensTheMenu(
      type: NSEvent.EventType,
      modifiers: NSEvent.ModifierFlags,
      isMenu: Bool
    ) throws {
      let event = try #require(
        NSEvent.mouseEvent(
          with: type,
          location: .zero,
          modifierFlags: modifiers,
          timestamp: 0,
          windowNumber: 0,
          context: nil,
          eventNumber: 0,
          clickCount: 1,
          pressure: 1
        )
      )

      #expect(StatusItemController.isMenuClick(event) == isMenu)
    }

    func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags, in window: NSWindow) throws -> NSEvent {
      try #require(
        NSEvent.keyEvent(
          with: .keyDown,
          location: .zero,
          modifierFlags: modifiers,
          timestamp: 0,
          windowNumber: window.windowNumber,
          context: nil,
          characters: characters,
          charactersIgnoringModifiers: characters,
          isARepeat: false,
          keyCode: characters == "\u{1b}" ? 53 : 43
        ))
    }

    @Test func openPanelTakesTheKeyboardSoCommandCommaOpensSettingsAndClosesIt() throws {
      var opened = 0

      let details = DetailPopover(
        coordinator: coordinator, chip: .unrecognized(brandString: nil), temperatureUnit: .celsius
      ) { opened += 1 }

      details.toggle(from: button)

      let panel = try #require(details.content?.window)

      #expect(panel.canBecomeKey)
      #expect(panel.performKeyEquivalent(with: try key(",", .command, in: panel)))
      #expect(opened == 1)
      #expect(!details.isShown)
    }

    @Test func escapeClosesThePanel() throws {
      details.toggle(from: button)

      let panel = try #require(details.content?.window)

      #expect(!panel.performKeyEquivalent(with: try key("\u{1b}", [], in: panel)))

      panel.keyDown(with: try key("\u{1b}", [], in: panel))

      #expect(!details.isShown)
    }

    @Test func metricTurnedOffWhileThePanelIsOpenShowsAtOnce() async throws {
      details.toggle(from: button)

      await waitUntil { details.content?[.gpu].value?.valueText == "12%" }

      coordinator.disable(.gpu)

      #expect(details.content?[.gpu].value?.statusText == "Turned off in Settings")
    }

    @Test func newHistoryCapacityShowsInTheOpenPanelAtOnce() async throws {
      details.toggle(from: button)

      let interval = try #require(coordinator.store[.gpu]?.interval)

      #expect(details.content?[.gpu].history?.content?.span == interval * 60)

      coordinator.setHistoryCapacity(20)

      #expect(details.content?[.gpu].history?.content?.span == interval * 20)
    }

    @Test func newTemperatureUnitShowsInTheOpenPanelAtOnce() async throws {
      coordinator.store.record(sample(value(50, .celsius), at: .now), for: .temperature)
      details.toggle(from: button)

      #expect(details.content?[.temperature].value?.valueText == "50°")

      details.temperatureUnit = .fahrenheit

      #expect(details.content?[.temperature].value?.valueText == "122°")
    }

    @Test func openingAndClosingDrawsNoMenuBarWidget() {
      menuBarView.show(readings(.cpu, after: [sample(value(40), at: .now)]), for: .cpu)
      CATransaction.flush()

      let draws = menuBarView.widgetViews.map(\.drawCount)

      details.toggle(from: button)
      CATransaction.flush()
      details.toggle(from: button)
      CATransaction.flush()

      #expect(menuBarView.widgetViews.map(\.drawCount) == draws)
    }
  }
}

/// The CPU sensor has 64 cores, more than any Mac, so the panel is tested at its largest.
private func sensor(for metric: Metric, calls: SensorCalls) -> RecordingSensor {
  var sensor = RecordingSensor(calls: calls)

  if metric == .cpu {
    sensor.coreKinds = Array(repeating: .performance, count: 48) + Array(repeating: .efficiency, count: 16)
  }

  return sensor
}

extension CALayer {
  fileprivate var withDescendants: [CALayer] {
    [self] + (sublayers ?? []).flatMap(\.withDescendants)
  }
}
