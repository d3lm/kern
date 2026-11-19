import AppKit
import Testing

@testable import KernCore
@testable import KernUI

@MainActor
final class MenuBarEditorTests {
  let defaults = TestDefaults()
  let preferences: PreferencesStore
  let pane: MenuBarSettings
  let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
  var changes = 0

  var editor: MenuBarEditor { pane.editor }
  var layout: MenuBarLayout { preferences.preferences.menuBarLayout }

  init() {
    preferences = PreferencesStore(defaults: defaults.defaults)
    pane = MenuBarSettings(preferences: preferences, store: MetricsStore(intervals: [:]))

    preferences.onChange = { [weak self] in
      self?.changes += 1

      self?.pane.show($0)
    }

    window.setContentSize(pane.form.size)
    window.contentView?.addSubview(pane.form)
  }

  func center(of widget: Widget) throws -> NSPoint {
    let view = try #require(
      editor.barView?.widgetViews.first { $0.widget == widget } ?? editor.shelfItems.first { $0.widget == widget })

    let frame = editor.frame(of: view)

    return NSPoint(x: frame.midX, y: frame.midY)
  }

  func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: type, location: editor.convert(point, to: nil), modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
  }

  func drag(from start: NSPoint, through points: [NSPoint], during: () throws -> Void = {}) throws {
    editor.mouseDown(with: try mouse(.leftMouseDown, at: start))

    for point in points {
      editor.mouseDragged(with: try mouse(.leftMouseDragged, at: point))
    }

    try during()
    editor.mouseUp(with: try mouse(.leftMouseUp, at: points.last ?? start))
  }

  func shownWidgets() -> [Widget] {
    editor.barView?.widgetViews.map(\.widget) ?? []
  }

  @Test func widgetDraggedAlongTheBarMovesAndTheOthersMakeRoomBeforeTheDrop() throws {
    let cpu = try center(of: .cpu)
    let end = NSPoint(x: try center(of: .memory).x + 8, y: cpu.y)

    try drag(from: cpu, through: [NSPoint(x: cpu.x + 4, y: cpu.y), end]) {
      #expect(shownWidgets() == [.temperature, .gpu, .memory, .cpu])
      #expect(editor.barView?.widgetViews.last?.alphaValue == MenuBarEditor.placeholderAlpha)
      #expect(!window.areCursorRectsEnabled)
      #expect(layout == .standard)
      #expect(editor.subviews.contains { $0 is NSImageView })
    }

    #expect(layout.widgets == [.temperature, .gpu, .memory, .cpu])
    #expect(shownWidgets() == [.temperature, .gpu, .memory, .cpu])
    #expect(editor.barView?.widgetViews.allSatisfy { $0.alphaValue == 1 } == true)
    #expect(!editor.subviews.contains { $0 is NSImageView })
    #expect(window.areCursorRectsEnabled)
    #expect(changes == 1)
  }

  @Test func widgetsSlideToTheirNewPlacesAndTheDraggedOneSettlesIntoItsPlace() async throws {
    window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
    window.orderFront(nil)

    defer { window.orderOut(nil) }

    let cpu = try center(of: .cpu)
    let end = NSPoint(x: try center(of: .memory).x + 8, y: cpu.y)
    let gpuBefore = editor.frame(of: try #require(editor.barView?.widgetViews.first { $0.widget == .gpu }))

    var gpu: WidgetView?

    try drag(from: cpu, through: [NSPoint(x: cpu.x + 4, y: cpu.y), end]) {
      gpu = editor.barView?.widgetViews.first { $0.widget == .gpu }

      #expect(gpu.map(editor.frame) == gpuBefore)
    }

    await waitUntil { gpu.map { editor.frame(of: $0).minX < gpuBefore.minX - 10 } ?? false }

    let placed = try #require(editor.barView?.widgetViews.last)

    #expect(placed.widget == .cpu)
    #expect(placed.alphaValue == 0)
    #expect(editor.subviews.contains { $0 is NSImageView })

    await waitUntil { !editor.subviews.contains { $0 is NSImageView } }

    #expect(placed.alphaValue == 1)
  }

  @Test func temperatureMovedFromTheFrontLandsAsWideAsItsReading() async throws {
    let store = MetricsStore(intervals: [.temperature: .seconds(10)])
    let pane = MenuBarSettings(preferences: preferences, store: store)
    let editor = pane.editor

    defer { pane.stop() }

    preferences.onChange = { pane.show($0) }

    store.record(sample(value(50, .celsius), at: .now), for: .temperature)

    for view in window.contentView?.subviews ?? [] {
      view.removeFromSuperview()
    }

    window.contentView?.addSubview(pane.form)
    window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
    window.orderFront(nil)

    defer { window.orderOut(nil) }

    func center(of widget: Widget) throws -> NSPoint {
      let frame = editor.frame(of: try #require(editor.barView?.widgetViews.first { $0.widget == widget }))

      return NSPoint(x: frame.midX, y: frame.midY)
    }

    func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
      try #require(
        NSEvent.mouseEvent(
          with: type, location: editor.convert(point, to: nil), modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    let start = try center(of: .temperature)
    let end = NSPoint(x: try center(of: .memory).x + 8, y: start.y)

    editor.mouseDown(with: try mouse(.leftMouseDown, at: start))
    editor.mouseDragged(with: try mouse(.leftMouseDragged, at: NSPoint(x: start.x + 4, y: start.y)))
    editor.mouseDragged(with: try mouse(.leftMouseDragged, at: end))
    editor.mouseUp(with: try mouse(.leftMouseUp, at: end))

    let landed = try #require(editor.barView?.widgetViews.last)
    let ghost = try #require(editor.subviews.first { $0 is NSImageView } as? NSImageView)

    let final = try #require(editor.barView?.layoutFrames.last)

    #expect(landed.widget == .temperature)
    #expect(final.width == MenuBarStyle().textWidth("50°", in: MenuBarStyle().valueFont))
    #expect(landed.frame == final)
    #expect(ghost.image?.size == final.size)

    await waitUntil { !editor.subviews.contains { $0 is NSImageView } }

    #expect(landed.frame == final)
    #expect(ghost.frame.size == final.size)
  }

  @Test func widgetDraggedOutOfTheBarIsRemovedAndWaitsOnTheShelf() throws {
    let gpu = try center(of: .gpu)
    let out = NSPoint(x: gpu.x, y: editor.shelf.frame.midY)

    #expect(editor.shelfItems.map(\.widget) == [.cores, .storage, .kern])

    try drag(from: gpu, through: [NSPoint(x: gpu.x, y: gpu.y + 10), out]) {
      #expect(shownWidgets() == [.temperature, .cpu, .memory])
      #expect(layout == .standard)
    }

    #expect(layout.widgets == [.temperature, .cpu, .memory])
    #expect(layout.order == MenuBarLayout.standard.order)
    #expect(editor.shelfItems.map(\.widget) == [.gpu, .cores, .storage, .kern])
    #expect(editor.emptyShelf.isHidden)
  }

  @Test func widgetsWithoutASwitchWaitOnTheShelfUndimmedAndTheShelfEmptiesOnceTheyAreInTheBar() throws {
    #expect(editor.shelfItems.map(\.name.stringValue) == ["CPU cores", "Storage", "Kern usage"])
    #expect(editor.shelfItems.allSatisfy { $0.menuBarView.alphaValue == 1 && $0.menuBarView.toolTip == nil })
    #expect(editor.emptyShelf.isHidden)

    for widget in [Widget.storage, .kern, .cores] {
      let last = editor.frame(of: try #require(editor.barView?.widgetViews.last))

      try drag(from: try center(of: widget), through: [NSPoint(x: last.maxX + 4, y: last.midY)])
    }

    #expect(layout.widgets == [.temperature, .cpu, .gpu, .memory, .storage, .kern, .cores])
    #expect(editor.shelfItems.isEmpty && !editor.emptyShelf.isHidden)
  }

  @Test func widgetDraggedInFromTheShelfIsShownWhereItIsDropped() throws {
    preferences.update { $0.menuBarLayout.setShown(false, .gpu) }

    let temperature = editor.frame(of: try #require(editor.barView?.widgetViews.first))

    try drag(from: try center(of: .gpu), through: [NSPoint(x: temperature.minX + 1, y: temperature.midY)])

    #expect(layout.widgets == [.gpu, .temperature, .cpu, .memory])
    #expect(editor.shelfItems.map(\.widget) == [.cores, .storage, .kern])
  }

  @Test func widgetDraggedFromTheShelfAndLetGoOutsideTheBarStaysHidden() throws {
    preferences.update { $0.menuBarLayout.setShown(false, .gpu) }

    changes = 0

    let gpu = try center(of: .gpu)

    try drag(from: gpu, through: [NSPoint(x: gpu.x + 40, y: gpu.y)])

    #expect(!layout.isShown(.gpu))
    #expect(editor.shelfItems.map(\.widget) == [.gpu, .cores, .storage, .kern])
    #expect(editor.shelfItems.first?.alphaValue == 1)
    #expect(changes == 0)
  }

  @Test func widgetPressedWithoutMovingStaysWhereItIs() throws {
    let cpu = try center(of: .cpu)

    try drag(from: cpu, through: [NSPoint(x: cpu.x + 2, y: cpu.y)]) {
      #expect(!editor.subviews.contains { $0 is NSImageView })
    }

    #expect(layout == .standard)
    #expect(changes == 0)
  }

  @Test func widgetNudgedWithoutChangingTheOrderKeepsTheHiddenWidgetsInTheirPlaces() throws {
    preferences.update { $0.menuBarLayout.setShown(false, .gpu) }

    changes = 0

    for widget in [Widget.memory, .cpu] {
      let point = try center(of: widget)

      try drag(from: point, through: [NSPoint(x: point.x + 4, y: point.y)])
    }

    #expect(layout.order == MenuBarLayout.standard.order)
    #expect(changes == 0)
  }

  @Test func escapeCancelsADragAndPutsTheWidgetBack() throws {
    let cpu = try center(of: .cpu)

    editor.mouseDown(with: try mouse(.leftMouseDown, at: cpu))
    editor.mouseDragged(with: try mouse(.leftMouseDragged, at: NSPoint(x: cpu.x, y: editor.shelf.frame.midY)))

    #expect(shownWidgets() == [.temperature, .gpu, .memory])
    #expect(window.firstResponder === editor)

    editor.cancelOperation(nil)
    editor.mouseUp(with: try mouse(.leftMouseUp, at: NSPoint(x: cpu.x, y: editor.shelf.frame.midY)))

    #expect(layout == .standard && changes == 0)
    #expect(shownWidgets() == [.temperature, .cpu, .gpu, .memory])
    #expect(!editor.subviews.contains { $0 is NSImageView })
    #expect(window.areCursorRectsEnabled)
  }

  @Test func escapeWithNothingPressedGoesOnToTheNextResponder() throws {
    let next = CancelRecorder()

    editor.nextResponder = next

    editor.cancelOperation(nil)

    #expect(next.cancels == 1)
    #expect(layout == .standard && changes == 0)
  }

  @Test func mouseDownAfterAMouseUpTheEditorNeverGotCancelsTheOldDrag() throws {
    let cpu = try center(of: .cpu)
    let temperature = try center(of: .temperature)
    let end = NSPoint(x: try center(of: .memory).x + 8, y: temperature.y)

    editor.mouseDown(with: try mouse(.leftMouseDown, at: cpu))
    editor.mouseDragged(with: try mouse(.leftMouseDragged, at: NSPoint(x: cpu.x, y: editor.shelf.frame.midY)))

    try drag(from: temperature, through: [NSPoint(x: temperature.x + 4, y: temperature.y), end])

    #expect(layout.widgets == [.cpu, .gpu, .memory, .temperature])
    #expect(editor.subviews.filter { $0 is NSImageView }.isEmpty)
  }

  @Test func ghostStaysInsideTheWindowsContent() throws {
    let cpu = try center(of: .cpu)
    let content = editor.convert(window.contentLayoutRect, from: nil)

    try drag(from: cpu, through: [NSPoint(x: cpu.x, y: cpu.y + 4), NSPoint(x: -500, y: -500)]) {
      let ghost = try #require(editor.subviews.first { $0 is NSImageView })

      #expect(content.contains(ghost.frame))
    }
  }

  @Test func settingChangedDuringADragIsKeptByTheDrop() throws {
    let cpu = try center(of: .cpu)
    let end = NSPoint(x: try center(of: .memory).x + 8, y: cpu.y)

    try drag(from: cpu, through: [NSPoint(x: cpu.x + 4, y: cpu.y), end]) {
      preferences.update { $0.menuBarLayout.setShowsLabel(false, .gpu) }
    }

    #expect(layout.widgets == [.temperature, .gpu, .memory, .cpu])
    #expect(layout.unlabeled == [.gpu])
  }

  @Test func rightClickOffersToMoveOrRemoveAShownWidgetAndToAddAHiddenOne() throws {
    func menu(at widget: Widget) throws -> NSMenu {
      try #require(editor.menu(for: try mouse(.rightMouseDown, at: try center(of: widget))))
    }

    let first = try menu(at: .temperature)

    #expect(
      first.items.map { $0.isSeparatorItem ? "-" : $0.title } == [
        "Move Left", "Move Right", "-", "Remove from Menu Bar",
      ])

    #expect(first.items.map(\.isEnabled) == [false, true, false, true])
    #expect(try !menu(at: .memory).items[1].isEnabled)

    first.performActionForItem(at: 1)

    #expect(layout.widgets == [.cpu, .temperature, .gpu, .memory])

    try menu(at: .gpu).performActionForItem(at: 3)

    #expect(layout.widgets == [.cpu, .temperature, .memory])

    let hidden = try menu(at: .gpu)

    #expect(hidden.items.map(\.title) == ["Add to Menu Bar"])

    hidden.performActionForItem(at: 0)

    #expect(layout.widgets == [.cpu, .temperature, .gpu, .memory])
    #expect(editor.menu(for: try mouse(.rightMouseDown, at: NSPoint(x: 1, y: 1))) == nil)
  }

  @Test func commandChosenAfterAnotherChangeKeepsThatChange() throws {
    let menu = try #require(editor.menu(for: try mouse(.rightMouseDown, at: try center(of: .memory))))

    preferences.update { $0.menuBarLayout.setShowsLabel(false, .cpu) }
    menu.performActionForItem(at: 0)

    #expect(layout.widgets == [.temperature, .cpu, .memory, .gpu])
    #expect(layout.unlabeled == [.cpu])
  }

  @Test func voiceOverReadsEachWidgetWhereItIsAndOffersTheSameCommands() throws {
    preferences.update { $0.menuBarLayout.setShown(false, .gpu) }
    window.setFrameOrigin(NSPoint(x: 100, y: 100))

    let bar = try #require(editor.barView?.widgetViews)
    let elements: [NSView] = bar + editor.shelfItems
    let children = editor.accessibilityChildren() as? [NSObject] ?? []

    #expect(
      elements.map { $0.accessibilityLabel() } == [
        "Temperature, in the menu bar, 1 of 3", "CPU, in the menu bar, 2 of 3", "Memory, in the menu bar, 3 of 3",
        "GPU, available", "CPU cores, available", "Storage, available", "Kern usage, available",
      ])

    #expect(elements.allSatisfy { $0.isAccessibilityElement() && $0.accessibilityRole() == .button })
    #expect(elements.allSatisfy { children.contains($0) })
    #expect(editor.shelfHeader.cell.map(children.contains) == true)

    for view in elements {
      #expect(view.accessibilityFrame() == window.convertToScreen(view.convert(view.bounds, to: nil)))
    }

    #expect(bar[0].accessibilityCustomActions()?.map(\.name) == ["Move Right", "Remove from Menu Bar"])

    _ = bar[1].accessibilityCustomActions()?.first { $0.name == "Move Left" }?.handler?()

    #expect(layout.widgets == [.cpu, .temperature, .memory])

    _ = elements[3].accessibilityCustomActions()?.first?.handler?()

    #expect(layout.widgets == [.cpu, .temperature, .gpu, .memory])
  }

  @Test func widgetOnTheShelfOfAMetricTurnedOffIsDimmedAndShowsNoOldValue() throws {
    let store = MetricsStore(intervals: [.gpu: .seconds(2)])
    let pane = MenuBarSettings(preferences: preferences, store: store)

    defer { pane.stop() }

    preferences.onChange = { pane.show($0) }

    store.record(sample(value(40), at: .now), for: .gpu)
    preferences.update { $0.menuBarLayout.setShown(false, .gpu) }

    let item = try #require(pane.editor.shelfItems.first)

    #expect(item.menuBarView.widgetViews.first?.content == .level(.percent(40), isStale: false))

    store.setEnabled(false, for: .gpu)
    preferences.update { $0.gpu.isEnabled = false }

    #expect(pane.editor.shelfItems.first === item)
    #expect(item.menuBarView.widgetViews.first?.content == .level(.measuring, isStale: false))
    #expect(item.menuBarView.alphaValue < 1)
    #expect(item.menuBarView.toolTip == "Hidden from the menu bar while GPU activity is off")
  }

  /// Takes every widget out of the bar before any reading, then gives each widget its widest reading on a Mac with as
  /// many cores as the M1 Max, which widens the items on the shelf after it was arranged.
  @Test func everyWidgetOnTheShelfStaysInsideItsBoxAndTheFormMakesRoomForItsRows() throws {
    let store = MetricsStore(intervals: Dictionary(uniqueKeysWithValues: Metric.allCases.map { ($0, .seconds(2)) }))
    let pane = MenuBarSettings(preferences: preferences, store: store)
    let cores = CoreUtilization(performance: Array(repeating: 100, count: 8), efficiency: [100, 100])

    defer { pane.stop() }

    preferences.onChange = { pane.show($0) }

    let oneRow = pane.form.size.height

    func check(_ moment: String) {
      let editor = pane.editor
      let shelf = editor.shelf.bounds.insetBy(dx: SettingsStyle().inset, dy: 0)

      for item in editor.shelfItems {
        #expect(shelf.contains(item.frame), "\(moment): \(item.widget) at \(item.frame) in \(shelf)")
      }

      #expect(editor.shelf.frame.height > MenuBarEditor.shelfHeight, "\(moment)")
      #expect(editor.bounds.height == editor.shelf.frame.maxY, "\(moment)")
      #expect(pane.form.sections[0].frame.height == editor.frame.maxY, "\(moment)")
      #expect(pane.form.size.height == oneRow + editor.shelf.frame.height - MenuBarEditor.shelfHeight, "\(moment)")
    }

    preferences.update { $0.menuBarLayout = MenuBarLayout(widgets: [], showsLabels: true)! }

    #expect(pane.editor.shelfItems.map(\.widget) == Widget.allCases)

    check("before readings")

    store.record(sample(value(100, cores: cores), at: .now), for: .cpu)
    store.record(sample(value(103, .celsius), at: .now), for: .temperature)
    store.record(sample(value(100), at: .now), for: .storage)
    store.record(sample(usage(250, megabytes: 127), at: .now), for: .kern)

    check("with the widest readings")
  }

  /// Leaves five widgets on the shelf, which fit in one row until sixteen cores widen the cores widget.
  @Test func readingThatNeedsAnotherRowOnTheShelfMakesTheFormTaller() throws {
    let store = MetricsStore(intervals: Dictionary(uniqueKeysWithValues: Metric.allCases.map { ($0, .seconds(2)) }))
    let pane = MenuBarSettings(preferences: preferences, store: store)
    let busy: (Int) -> [Double] = { Array(repeating: 50, count: $0) }
    let cores = CoreUtilization(performance: busy(12), efficiency: busy(4))

    defer { pane.stop() }

    preferences.onChange = { pane.show($0) }

    let oneRow = pane.form.size.height

    preferences.update { $0.menuBarLayout = MenuBarLayout(widgets: [.gpu, .memory], showsLabels: true)! }

    #expect(pane.editor.shelfItems.map(\.widget) == [.temperature, .cpu, .cores, .storage, .kern])
    #expect(pane.editor.shelf.frame.height == MenuBarEditor.shelfHeight)
    #expect(pane.form.size.height == oneRow)

    store.record(sample(value(50, cores: cores), at: .now), for: .cpu)

    let shelf = pane.editor.shelf.bounds.insetBy(dx: SettingsStyle().inset, dy: 0)
    let added = pane.editor.shelf.frame.height - MenuBarEditor.shelfHeight

    #expect(added > 0)
    #expect(pane.editor.shelfItems.allSatisfy { shelf.contains($0.frame) })
    #expect(pane.form.sections[0].frame.height == pane.editor.frame.maxY)
    #expect(pane.form.size.height == oneRow + added)
  }

  @Test func kernUsageOnTheShelfIsADashOnlyUntilItsFirstReading() throws {
    let store = MetricsStore(intervals: [.kern: .seconds(2)])
    let pane = MenuBarSettings(preferences: preferences, store: store)

    defer { pane.stop() }

    let item = try #require(pane.editor.shelfItems.first { $0.widget == .kern })

    #expect(item.menuBarView.widgetViews.first?.content == .noReading)

    store.record(sample(usage(3.2, megabytes: 28), at: .now), for: .kern)

    #expect(item.menuBarView.widgetViews.first?.content == .stacked("3.2%", "28 MB", isStale: false))
  }

  /// Two widths that differ by an odd number of points can be centered on each other only on a display's pixels.
  @Test func widgetOnTheShelfIsCenteredUnderItsNameToThePixel() throws {
    let store = MetricsStore(intervals: [.kern: .seconds(2), .temperature: .seconds(10)])
    let pane = MenuBarSettings(preferences: preferences, store: store)

    defer { pane.stop() }

    preferences.onChange = { pane.show($0) }

    preferences.update { $0.menuBarLayout.setShown(false, .temperature) }

    for view in window.contentView?.subviews ?? [] {
      view.removeFromSuperview()
    }

    window.contentView?.addSubview(pane.form)

    let pixel = 1 / window.backingScaleFactor

    for state in [nil, value(63, .celsius), value(103, .celsius)] as [SampleState?] {
      if let state { store.record(sample(state, at: .now), for: .temperature) }

      for item in pane.editor.shelfItems {
        let offset = abs(item.menuBarView.frame.midX - item.name.frame.midX)

        #expect(offset <= pixel / 2, "\(item.widget) \(String(describing: state))")
      }
    }
  }

  @Test func readingOnTheShelfStaysCenteredUnderItsNameAndKeepsTheShelfSpacingAsItsWidthChanges() throws {
    let store = MetricsStore(intervals: [.temperature: .seconds(10), .kern: .seconds(2)])
    let pane = MenuBarSettings(preferences: preferences, store: store)

    defer { pane.stop() }

    preferences.onChange = { pane.show($0) }

    preferences.update { $0.menuBarLayout.setShown(false, .temperature) }

    func check(_ moment: String) throws {
      let items = pane.editor.shelfItems
      let temperature = try #require(items.first { $0.widget == .temperature })
      let widget = try #require(temperature.menuBarView.widgetViews.first)

      #expect(temperature.menuBarView.frame.width == widget.frame.width, "\(moment)")
      #expect(abs(temperature.menuBarView.frame.midX - temperature.name.frame.midX) <= 0.5, "\(moment)")
      #expect(Set(zip(items, items.dropFirst()).map { $1.frame.minX - $0.frame.maxX }).count == 1, "\(moment)")
    }

    store.record(sample(value(63, .celsius), at: .now), for: .temperature)
    try check("63°")

    store.record(sample(value(103, .celsius), at: .now), for: .temperature)
    try check("103°")

    store.record(sample(usage(3.2, megabytes: 28), at: .now), for: .kern)
    try check("Kern usage shown")
  }

  @Test func widgetOfAMetricThatIsOffIsDimmedAndSaysWhy() throws {
    preferences.update { $0.memory.isEnabled = false }

    let memory = try #require(editor.barView?.widgetViews.last)

    #expect(memory.widget == .memory)
    #expect(memory.alphaValue < 1)
    #expect(memory.toolTip == "Hidden from the menu bar while Memory is off")
    #expect(editor.barView?.widgetViews.dropLast().allSatisfy { $0.alphaValue == 1 && $0.toolTip == nil } == true)
  }

  @Test func labelSwitchesTurnEachWidgetsLabelOffInTheBarAndOnTheShelf() throws {
    preferences.update { $0.menuBarLayout.setShown(false, .gpu) }

    func widths() throws -> (bar: CGFloat, shelf: CGFloat) {
      let cpu = try #require(editor.barView?.widgetViews.first { $0.widget == .cpu })
      let gpu = try #require(editor.shelfItems.first?.menuBarView)

      return (cpu.frame.width, gpu.frame.width)
    }

    let labeled = try widths()

    try #require(pane.labelSwitches[.cpu]).performClick(nil)
    try #require(pane.labelSwitches[.gpu]).performClick(nil)

    let unlabeled = try widths()

    #expect(layout.unlabeled == [.cpu, .gpu])
    #expect(pane.labelSwitches[.memory]?.state == .on)
    #expect(unlabeled.bar < labeled.bar)
    #expect(unlabeled.shelf < labeled.shelf)
  }
}

final class CancelRecorder: NSResponder {
  private(set) var cancels = 0

  override func cancelOperation(_ sender: Any?) {
    cancels += 1
  }
}
