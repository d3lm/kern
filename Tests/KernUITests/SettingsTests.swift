import AppKit
import ServiceManagement
import Testing

@testable import KernCore
@testable import KernUI

@MainActor
final class SettingsTests {
  let calls: [Metric: SensorCalls] = Dictionary(uniqueKeysWithValues: Metric.allCases.map { ($0, SensorCalls()) })
  let coordinator: MetricsCoordinator<ContinuousClock>

  init() {
    let calls = calls

    coordinator = MetricsCoordinator(
      providers: Dictionary(
        uniqueKeysWithValues: Metric.allCases.map { ($0, MetricProvider(sensor: RecordingSensor(calls: calls[$0]!))) }
      ))
  }

  func isOpen(_ metric: Metric) -> Bool {
    calls[metric]!.all.last { $0 == "open" || $0 == "close" } == "open"
  }

  @Test func turningAMetricOffStopsItsSensorAndEmptiesItsReadings() async {
    var preferences = Preferences.standard

    coordinator.apply(preferences)
    coordinator.start()

    await waitUntil { coordinator.store[.temperature]?.latest != nil }

    preferences.temperature.isEnabled = false

    coordinator.apply(preferences)

    await waitUntil { !isOpen(.temperature) }

    let reads = calls[.temperature]!.all.count { $0 == "read" }

    #expect(coordinator.store[.temperature]?.isEnabled == false)
    #expect(coordinator.store[.temperature]?.latest == nil)
    #expect(isOpen(.cpu) && isOpen(.gpu) && isOpen(.memoryPressure))

    try? await Task.sleep(for: .milliseconds(100))

    #expect(calls[.temperature]!.all.count { $0 == "read" } == reads)
  }

  @Test func memoryTurnsUsedMemoryAndMemoryPressureOffTogetherAndNothingElse() async {
    var preferences = Preferences.standard

    coordinator.apply(preferences)

    coordinator.areDetailsVisible = true

    coordinator.start()

    await waitUntil { isOpen(.memory) && isOpen(.memoryPressure) }

    preferences.memory.isEnabled = false

    coordinator.apply(preferences)

    await waitUntil { !isOpen(.memory) && !isOpen(.memoryPressure) }

    #expect(coordinator.store[.memory]?.isEnabled == false)
    #expect(coordinator.store[.memoryPressure]?.isEnabled == false)
    #expect(isOpen(.cpu) && isOpen(.gpu) && isOpen(.temperature))
  }

  @Test func kernUsageIsSampledOnlyWhileItsWidgetIsInTheMenuBar() async {
    var preferences = Preferences.standard

    coordinator.apply(preferences)
    coordinator.start()

    await waitUntil { isOpen(.cpu) && coordinator.store[.cpu]?.latest != nil }

    #expect(!isOpen(.kern))
    #expect(calls[.kern]!.all.isEmpty)
    #expect(coordinator.store[.kern]?.isEnabled == false)

    preferences.menuBarLayout.place(.kern, before: .cpu)
    coordinator.apply(preferences)

    await waitUntil { coordinator.store[.kern]?.latest != nil }

    #expect(isOpen(.kern))
    #expect(coordinator.store[.kern]?.interval == Metric.kern.defaultInterval)

    preferences.menuBarLayout.setShown(false, .kern)
    coordinator.apply(preferences)

    await waitUntil { !isOpen(.kern) }

    #expect(coordinator.store[.kern]?.isEnabled == false)
    #expect(coordinator.store[.kern]?.latest == nil)
  }

  @Test func kernUsageIsSampledWhileSettingsIsOpenToShowItOnTheShelf() async {
    coordinator.apply(.standard)
    coordinator.start()

    await waitUntil { isOpen(.cpu) && coordinator.store[.cpu]?.latest != nil }

    #expect(!isOpen(.kern))

    coordinator.apply(.standard, isSettingsOpen: true)

    await waitUntil { coordinator.store[.kern]?.latest != nil }

    #expect(isOpen(.kern))

    coordinator.apply(.standard, isSettingsOpen: false)

    await waitUntil { !isOpen(.kern) }

    #expect(coordinator.store[.kern]?.isEnabled == false)
  }

  @Test func intervalsHistoryLengthAndLowPowerBehaviorReachTheCoordinator() {
    var preferences = Preferences.standard

    preferences.cpu.interval = 7
    preferences.memory.interval = 30
    preferences.graphSamples = 240
    preferences.lowPowerModeBehavior = .override

    coordinator.apply(preferences)

    #expect(coordinator.store[.cpu]?.interval == .seconds(7))
    #expect(coordinator.store[.memory]?.interval == .seconds(30))
    #expect(coordinator.store[.memoryPressure]?.interval == .seconds(30))
    #expect(coordinator.store[.gpu]?.interval == .seconds(2))
    #expect(coordinator.store.historyCapacity == 240)
    #expect(coordinator.store[.cpu]?.history?.capacity == 240)
    #expect(coordinator.lowPowerModeBehavior == .override)
  }

  /// A metric has its sensor open exactly while it has a schedule, so the test waits until the sensors match the
  /// settings.
  @Test func hundredRandomSettingsChangesLeaveTheSettingsLastMade() async {
    let defaults = TestDefaults()
    let preferences = PreferencesStore(defaults: defaults.defaults)

    var random = SplitMix64(state: 10)

    preferences.onChange = { [coordinator] in coordinator.apply($0) }

    coordinator.apply(preferences.preferences)
    coordinator.start()

    for _ in 1...100 {
      let monitor = Monitor.allCases.randomElement(using: &random)!
      let widget = Widget.allCases.randomElement(using: &random)!
      let target = Widget.allCases.randomElement(using: &random)!

      preferences.update { preferences in
        switch Int.random(in: 0..<7, using: &random) {
        case 0: preferences[monitor].isEnabled.toggle()
        case 1: preferences[monitor].interval = Int.random(in: monitor.intervals, using: &random)
        case 2: preferences.graphSamples = Int.random(in: Preferences.graphSampleCounts, using: &random)
        case 3: preferences.temperatureUnit = preferences.temperatureUnit == .celsius ? .fahrenheit : .celsius
        case 4: preferences.lowPowerModeBehavior = preferences.lowPowerModeBehavior == .adaptive ? .override : .adaptive
        case 5: preferences.menuBarLayout.setShown(!preferences.menuBarLayout.isShown(widget), widget)
        default: preferences.menuBarLayout.place(widget, before: target == widget ? nil : target)
        }
      }
    }

    let final = preferences.preferences

    func isEnabled(_ metric: Metric) -> Bool {
      Monitor(metric).map { final[$0].isEnabled } ?? final.menuBarLayout.isShown(.kern)
    }

    func isSampled(_ metric: Metric) -> Bool {
      isEnabled(metric) && !metric.isSampledOnlyForDetails
    }

    await waitUntil { Metric.allCases.allSatisfy { isOpen($0) == isSampled($0) } }

    for metric in Metric.allCases {
      let readings = coordinator.store[metric]
      let interval = Monitor(metric).map { Duration.seconds(final[$0].interval) } ?? metric.defaultInterval

      #expect(readings?.isEnabled == isEnabled(metric), "\(metric)")
      #expect(readings?.interval == interval, "\(metric)")
      #expect(calls[metric]!.all.count { $0 == "open" } - calls[metric]!.all.count { $0 == "close" } <= 1)
    }

    #expect(coordinator.store.historyCapacity == final.graphSamples)
    #expect(coordinator.lowPowerModeBehavior == final.lowPowerModeBehavior)
    #expect(PreferencesStore(defaults: defaults.defaults).preferences == final)
  }

  @Test func itemMenuOpensSettingsWithCommandCommaAndQuitsWithCommandQ() throws {
    let target = Target()
    let menu = StatusItemController.menu(settingsTarget: target, settingsAction: #selector(Target.fire))

    #expect(menu.items.map(\.title) == ["Settings…", "", "Quit Kern"])
    #expect(menu.items[0].keyEquivalent == "," && menu.items[0].keyEquivalentModifierMask == .command)
    #expect(menu.items[2].keyEquivalent == "q" && menu.items[2].action == #selector(NSApplication.terminate(_:)))

    menu.performActionForItem(at: 0)

    #expect(target.fired == 1)
  }

  @Test func loginItemRegistersAndUnregistersWithTheSystem() {
    let service = FakeLoginItemService()
    let loginItem = LoginItemManager(service: service)

    #expect(!loginItem.isEnabled)

    loginItem.setEnabled(true)

    #expect(loginItem.isEnabled && service.calls == ["register"])

    loginItem.setEnabled(true)
    loginItem.setEnabled(false)

    #expect(!loginItem.isEnabled && service.calls == ["register", "unregister"])

    loginItem.setEnabled(false)

    #expect(service.calls == ["register", "unregister"])
  }

  @Test func loginItemThatMacOSHoldsForApprovalCountsAsOn() {
    let service = FakeLoginItemService()

    service.status = .requiresApproval

    #expect(LoginItemManager(service: service).isEnabled)
  }

  @Test func failedLoginItemChangeSaysWhyAndKeepsTheStatusOfMacOS() {
    let service = FakeLoginItemService()
    let loginItem = LoginItemManager(service: service)

    service.failure = SensorError("not allowed")

    loginItem.setEnabled(true)

    #expect(!loginItem.isEnabled)
    #expect(loginItem.failure != nil)

    service.failure = nil

    loginItem.setEnabled(true)

    #expect(loginItem.isEnabled && loginItem.failure == nil)
  }

  func settingsWindow(
    _ preferences: PreferencesStore,
    loginItem: LoginItemManager = LoginItemManager(service: FakeLoginItemService()),
    onClose: @escaping @MainActor () -> Void = {}
  ) -> SettingsWindowController {
    let settings = SettingsWindowController(
      preferences: preferences, loginItem: loginItem, store: coordinator.store, onClose: onClose)

    preferences.onChange = { [coordinator, weak settings] in
      coordinator.apply($0)
      settings?.show($0)
    }

    return settings
  }

  func pane<Pane: SettingsPane>(_ type: Pane.Type, in settings: SettingsWindowController) throws -> Pane {
    try #require(settings.panes.lazy.compactMap { $0 as? Pane }.first)
  }

  @Test func settingsWindowHasATabForEachGroupAndIsReleasedWhenClosed() async throws {
    weak var window: NSWindow?
    weak var controller: SettingsWindowController?
    weak var form: SettingsForm?
    var closed = 0

    do {
      let settings = settingsWindow(PreferencesStore(defaults: TestDefaults().defaults)) { closed += 1 }

      window = settings.window
      controller = settings
      form = settings.panes.last?.form

      #expect(settings.tabs.tabViewItems.map(\.label) == ["General", "Metrics", "Menu Bar"])
      #expect(settings.panes.map(\.title) == ["General", "Metrics", "Menu Bar"])
      #expect(settings.tabs.tabStyle == .toolbar)
      #expect(settings.window.styleMask == [.titled, .closable])
      #expect(settings.window.contentLayoutRect.size == settings.panes[0].preferredContentSize)

      for pane in settings.panes {
        #expect(pane.preferredContentSize.width == SettingsStyle().width, "\(pane.title ?? "")")
        #expect(pane.preferredContentSize == pane.form.frame.size, "\(pane.title ?? "")")
      }

      settings.window.close()
    }

    #expect(closed == 1)

    await waitUntil { window == nil && controller == nil && form == nil }
  }

  @Test func chosenTabIsShownInTheLabelColorAndAClickOnAnotherTabChoosesIt() throws {
    let settings = settingsWindow(PreferencesStore(defaults: TestDefaults().defaults))
    let toolbar = try #require(settings.window.toolbar)
    let buttons = toolbar.items.compactMap { $0.view as? SettingsTabButton }

    #expect(buttons.map(\.title) == ["General", "Metrics", "Menu Bar"])
    #expect(buttons.map(\.isSelected) == [true, false, false])
    #expect(buttons.allSatisfy { !$0.mouseDownCanMoveWindow && $0.acceptsFirstMouse(for: nil) })
    #expect(toolbar.displayMode == .iconOnly)
    #expect(toolbar.selectedItemIdentifier == nil)

    func mouse(_ type: NSEvent.EventType, at point: NSPoint, on button: SettingsTabButton) throws -> NSEvent {
      try #require(
        NSEvent.mouseEvent(
          with: type, location: button.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0,
          context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    let middle = NSPoint(x: buttons[1].bounds.midX, y: buttons[1].bounds.midY)

    #expect(buttons[1].hitTest(buttons[1].convert(middle, to: buttons[1].superview)) === buttons[1])

    buttons[1].mouseDown(with: try mouse(.leftMouseDown, at: middle, on: buttons[1]))

    #expect(settings.tabs.selectedTabViewItemIndex == 0)

    buttons[1].mouseUp(with: try mouse(.leftMouseUp, at: NSPoint(x: -50, y: middle.y), on: buttons[1]))

    #expect(settings.tabs.selectedTabViewItemIndex == 0)

    buttons[1].mouseDown(with: try mouse(.leftMouseDown, at: middle, on: buttons[1]))
    buttons[1].mouseUp(with: try mouse(.leftMouseUp, at: middle, on: buttons[1]))

    #expect(settings.tabs.selectedTabViewItemIndex == 1)
    #expect(buttons[2].accessibilityPerformPress())

    #expect(settings.tabs.selectedTabViewItemIndex == 2)
    #expect(settings.window.title == "Menu Bar")
    #expect(buttons.map(\.isSelected) == [false, false, true])
    #expect(toolbar.selectedItemIdentifier == nil)
  }

  @Test func sectionExplanationsAreBehindInfoButtons() async throws {
    let settings = settingsWindow(PreferencesStore(defaults: TestDefaults().defaults))
    let sections = settings.panes.flatMap(\.form.sections)
    let explained = sections.filter { $0.infoButton != nil }.map { $0.header.accessibilityLabel() }

    #expect(explained == ["Low Power Mode", "Sampling", "Menu Bar"])

    let info = try #require(sections.first { $0.header.accessibilityLabel() == "Low Power Mode" }?.infoButton)

    #expect(info.accessibilityLabel() == "About Low Power Mode")
    #expect(info.text.hasPrefix("Adaptive samples less often"))

    settings.window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
    settings.window.orderFront(nil)

    defer { settings.window.close() }

    info.performClick(nil)

    let popover = try #require(info.popover)

    #expect(popover.isShown)

    info.performClick(nil)

    #expect(info.popover === popover)

    await waitUntil { !popover.isShown }
  }

  @Test func settingsWindowClosesWithCommandWWithoutAMainMenu() throws {
    var closed = 0

    let settings = settingsWindow(PreferencesStore(defaults: TestDefaults().defaults)) { closed += 1 }

    /// `typed` is what the key types without ⌘, which differs from `key` on a layout such as Dvorak – QWERTY ⌘.
    func key(_ key: String, _ modifiers: NSEvent.ModifierFlags, typed: String? = nil) throws -> NSEvent {
      try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
          windowNumber: settings.window.windowNumber, context: nil, characters: key,
          charactersIgnoringModifiers: typed ?? key, isARepeat: false, keyCode: 0))
    }

    #expect(NSApp.mainMenu?.items.contains { $0.submenu?.title == "Edit" } != true)
    #expect(!settings.window.performKeyEquivalent(with: try key("x", .command)))
    #expect(!settings.window.performKeyEquivalent(with: try key("w", [.command, .option])))
    #expect(!settings.window.performKeyEquivalent(with: try key("W", [.command, .shift])))
    #expect(!settings.window.performKeyEquivalent(with: try key(",", .command, typed: "w")))
    #expect(closed == 0)

    #expect(settings.window.performKeyEquivalent(with: try key("W", [.command, .capsLock], typed: ",")))
    #expect(closed == 1)
  }

  @Test func windowFollowsATabThatGrowsWhileItIsShownAndKeepsItsTop() throws {
    let service = FakeLoginItemService()

    let settings = settingsWindow(
      PreferencesStore(defaults: TestDefaults().defaults), loginItem: LoginItemManager(service: service))

    let general = try pane(GeneralSettings.self, in: settings)

    settings.window.layoutIfNeeded()

    let before = settings.window.contentRect(forFrameRect: settings.window.frame)

    service.status = .requiresApproval

    general.refreshLoginItem()
    settings.window.layoutIfNeeded()

    let after = settings.window.contentRect(forFrameRect: settings.window.frame)

    #expect(!general.approvalRow.isHidden)
    #expect(after.height == general.preferredContentSize.height)
    #expect(after.height > before.height)
    #expect(after.maxY == before.maxY)
    #expect(general.form.frame.height == general.preferredContentSize.height)

    #expect(
      general.restoreButton.convert(general.restoreButton.bounds, to: general.form).maxY <= general.form.frame.height)

    let box = general.form.sections[2].content

    #expect(general.restoreButton.frame.minX + general.restoreButton.alignmentRectInsets.left == box.frame.minX)

    #expect(
      general.restoreButton.frame.minY + general.restoreButton.alignmentRectInsets.top
        == box.frame.maxY + SettingsStyle().sectionSpacing)
  }

  @Test func intervalPopUpOffersChoicesInTheRangeOfItsMetricWithOffAfterThem() throws {
    let metrics = try pane(
      MetricsSettings.self, in: settingsWindow(PreferencesStore(defaults: TestDefaults().defaults)))

    let temperature = try #require(metrics.intervals[.temperature])

    #expect(
      temperature.itemArray.map { $0.isSeparatorItem ? "-" : $0.title } == [
        "Every 5 seconds", "Every 10 seconds", "Every 15 seconds", "Every 30 seconds", "Every minute",
        "Every 2 minutes", "Every 5 minutes", "-", "Custom…", "-", "Off",
      ])

    #expect(temperature.titleOfSelectedItem == "Every 10 seconds")

    for monitor in Monitor.allCases {
      #expect(monitor.intervalChoices.allSatisfy(monitor.intervals.contains), "\(monitor)")
      #expect(monitor.intervalChoices.contains(Preferences.standard[monitor].interval), "\(monitor)")
    }
  }

  @Test func choosingOffTurnsAMetricOffAndKeepsItsIntervalForWhenItIsOnAgain() throws {
    let preferences = PreferencesStore(defaults: TestDefaults().defaults)
    let metrics = try pane(MetricsSettings.self, in: settingsWindow(preferences))
    let gpu = try #require(metrics.intervals[.gpu])

    func choose(_ tag: Int) {
      gpu.selectItem(withTag: tag)
      gpu.sendAction(gpu.action, to: gpu.target)
    }

    choose(15)

    #expect(preferences.preferences.gpu == MonitorSettings(isEnabled: true, interval: 15))

    choose(ChoicePopUp.off)

    #expect(preferences.preferences.gpu == MonitorSettings(isEnabled: false, interval: 15))
    #expect(gpu.titleOfSelectedItem == "Off")

    choose(5)

    #expect(preferences.preferences.gpu == MonitorSettings(isEnabled: true, interval: 5))
    #expect(gpu.titleOfSelectedItem == "Every 5 seconds")
  }

  @Test func intervalSetOutsideTheChoicesIsListedInOrderAndSelected() throws {
    let preferences = PreferencesStore(defaults: TestDefaults().defaults)
    let metrics = try pane(MetricsSettings.self, in: settingsWindow(preferences))
    let cpu = try #require(metrics.intervals[.cpu])

    preferences.update { $0.cpu.interval = 7 }

    #expect(
      cpu.itemTitles.prefix(5) == [
        "Every 2 seconds", "Every 3 seconds", "Every 5 seconds", "Every 7 seconds", "Every 10 seconds",
      ])

    #expect(cpu.titleOfSelectedItem == "Every 7 seconds")
  }

  /// Shows the window far off screen, because a popover opens only from a window that is on screen.
  func chooseCustom(_ popUp: ChoicePopUp, in metrics: MetricsSettings) throws -> CustomValueEditor {
    let window = try #require(popUp.window)

    window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
    window.orderFront(nil)
    popUp.selectItem(withTag: ChoicePopUp.custom)
    popUp.sendAction(popUp.action, to: popUp.target)

    let editor = try #require(metrics.customEditor)

    #expect(editor.popover.isShown)

    return editor
  }

  func type(_ text: String, in editor: CustomValueEditor, ending command: Selector) {
    editor.field.stringValue = text

    editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    _ = editor.control(editor.field, textView: NSTextView(), doCommandBy: command)
  }

  @Test func customIntervalTypedInThePopoverIsAppliedWithReturnAndListed() async throws {
    let preferences = PreferencesStore(defaults: TestDefaults().defaults)
    let settings = settingsWindow(preferences)

    defer { settings.window.close() }

    let metrics = try pane(MetricsSettings.self, in: settings)
    let gpu = try #require(metrics.intervals[.gpu])

    settings.tabs.selectedTabViewItemIndex = 1

    preferences.update { $0.gpu.isEnabled = false }

    let editor = try chooseCustom(gpu, in: metrics)

    #expect(gpu.titleOfSelectedItem == "Off")
    #expect(editor.field.stringValue == "2")

    type("7", in: editor, ending: #selector(NSResponder.insertNewline(_:)))

    #expect(editor.stepper.integerValue == 7)
    await waitUntil { !editor.popover.isShown }
    #expect(preferences.preferences.gpu == MonitorSettings(isEnabled: true, interval: 7))
    #expect(gpu.titleOfSelectedItem == "Every 7 seconds")
  }

  @Test func escapeClosesTheCustomIntervalWithoutApplyingIt() async throws {
    let preferences = PreferencesStore(defaults: TestDefaults().defaults)
    let settings = settingsWindow(preferences)

    defer { settings.window.close() }

    let metrics = try pane(MetricsSettings.self, in: settings)

    settings.tabs.selectedTabViewItemIndex = 1

    let editor = try chooseCustom(try #require(metrics.intervals[.temperature]), in: metrics)

    type("45", in: editor, ending: #selector(NSResponder.cancelOperation(_:)))

    await waitUntil { !editor.popover.isShown }
    #expect(preferences.preferences.temperature.interval == 10)
  }

  @Test func escapeOnTheStepperClosesTheCustomIntervalWithoutApplyingIt() async throws {
    let preferences = PreferencesStore(defaults: TestDefaults().defaults)
    let settings = settingsWindow(preferences)

    defer { settings.window.close() }

    let metrics = try pane(MetricsSettings.self, in: settings)

    settings.tabs.selectedTabViewItemIndex = 1

    let editor = try chooseCustom(try #require(metrics.intervals[.temperature]), in: metrics)

    editor.field.stringValue = "45"

    editor.stepper.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil)

    await waitUntil { !editor.popover.isShown }

    #expect(preferences.preferences.temperature.interval == 10)
  }

  @Test(arguments: [("1000", 300), ("0", 5), ("-4", 5), ("12.4", 12), ("soon", 10), ("", 10)])
  func customIntervalOutsideTheRangeMovesToItsNearestEnd(text: String, interval: Int) throws {
    let preferences = PreferencesStore(defaults: TestDefaults().defaults)
    let settings = settingsWindow(preferences)

    defer { settings.window.close() }

    let metrics = try pane(MetricsSettings.self, in: settings)

    settings.tabs.selectedTabViewItemIndex = 1

    let editor = try chooseCustom(try #require(metrics.intervals[.temperature]), in: metrics)

    type(text, in: editor, ending: #selector(NSResponder.insertNewline(_:)))

    #expect(preferences.preferences.temperature.interval == interval)
  }

  @Test func stepperOfTheCustomIntervalChangesTheTypedValue() throws {
    let preferences = PreferencesStore(defaults: TestDefaults().defaults)
    let settings = settingsWindow(preferences)

    defer { settings.window.close() }

    let metrics = try pane(MetricsSettings.self, in: settings)

    settings.tabs.selectedTabViewItemIndex = 1

    let editor = try chooseCustom(metrics.graphSamples, in: metrics)

    editor.stepper.integerValue = 61

    editor.stepper.sendAction(editor.stepper.action, to: editor.stepper.target)

    #expect(editor.field.stringValue == "61")
    #expect(preferences.preferences.graphSamples == 60)

    editor.popover.performClose(nil)

    #expect(preferences.preferences.graphSamples == 61)
    #expect(metrics.graphSamples.titleOfSelectedItem == "61 samples")
  }

  /// Quitting closes the window too, so a value typed before ⌘Q is kept as one typed before ⌘W.
  @Test func closingTheWindowAppliesTheValueTypedInCustom() async throws {
    let preferences = PreferencesStore(defaults: TestDefaults().defaults)
    let settings = settingsWindow(preferences)
    let metrics = try pane(MetricsSettings.self, in: settings)

    settings.tabs.selectedTabViewItemIndex = 1

    let editor = try chooseCustom(metrics.graphSamples, in: metrics)

    editor.field.stringValue = "90"

    settings.window.close()

    await waitUntil { !editor.popover.isShown }

    #expect(preferences.preferences.graphSamples == 90)
  }

  @Test func commandWInCustomReachesTheSettingsWindow() async throws {
    var closed = 0

    let settings = settingsWindow(PreferencesStore(defaults: TestDefaults().defaults)) { closed += 1 }
    let metrics = try pane(MetricsSettings.self, in: settings)

    settings.tabs.selectedTabViewItemIndex = 1

    let editor = try chooseCustom(metrics.graphSamples, in: metrics)

    let key = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
        characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))

    #expect(editor.view.window?.parent === settings.window)
    #expect(editor.view.performKeyEquivalent(with: key))
    #expect(closed == 1)
  }

  @Test func graphSamplesSayHowLongTheCPUChartReachesBack() throws {
    let preferences = PreferencesStore(defaults: TestDefaults().defaults)
    let metrics = try pane(MetricsSettings.self, in: settingsWindow(preferences))

    #expect(metrics.graphSamples.itemTitles.first == "20 samples")
    #expect(!metrics.graphSamples.itemArray.contains { $0.tag == ChoicePopUp.off })

    metrics.graphSamples.selectItem(withTag: 120)
    metrics.graphSamples.sendAction(metrics.graphSamples.action, to: metrics.graphSamples.target)
    preferences.update { $0.cpu.interval = 5 }

    #expect(preferences.preferences.graphSamples == 120)
    #expect(metrics.graphRow.subtitle == "The CPU chart shows the last 10 minutes.")
  }

  @Test func graphSamplesSayHowLongTheCPUChartReachesBackInLowPowerMode() throws {
    let preferences = PreferencesStore(defaults: TestDefaults().defaults)
    let metrics = try pane(MetricsSettings.self, in: settingsWindow(preferences))

    #expect(metrics.graphRow.subtitle == "The CPU chart shows the last 2 minutes.")

    coordinator.powerState.isLowPowerModeEnabled = true

    #expect(metrics.graphRow.subtitle == "The CPU chart shows the last 5 minutes.")

    preferences.update { $0.lowPowerModeBehavior = .override }

    #expect(metrics.graphRow.subtitle == "The CPU chart shows the last 2 minutes.")
  }

  @Test func popUpShowsItsArrowsAfterTheWholeTitleAndIsHighlightedUnderThePointer() throws {
    let popUp = ChoicePopUp(title: "CPU usage")
    let cell = try #require(popUp.cell as? ChoicePopUpCell)

    func crossing(_ type: NSEvent.EventType) throws -> NSEvent {
      try #require(
        NSEvent.enterExitEvent(
          with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
          trackingNumber: 0, userData: nil))
    }

    popUp.show([2, 5], title: MetricsSettings.title(every:), selected: 2, offersOff: true)
    popUp.setFrameSize(popUp.intrinsicContentSize)

    let title = NSAttributedString(string: "Every 2 seconds", attributes: [.font: try #require(popUp.font)])
    let titleRect = cell.drawingRect(forBounds: popUp.bounds)
    let indicator = cell.indicatorRect(forBounds: popUp.bounds)

    #expect(titleRect.width >= title.size().width)
    #expect(indicator.maxX == popUp.bounds.maxX - popUp.alignmentRectInsets.right)
    #expect(titleRect.maxX <= indicator.minX)

    let window = NSWindow(contentRect: popUp.frame, styleMask: [], backing: .buffered, defer: true)
    let inside = NSPoint(x: popUp.bounds.midX, y: popUp.bounds.midY)

    var pointer: NSPoint?

    window.contentView?.addSubview(popUp)

    popUp.pointerLocation = { pointer }

    draw(popUp)

    #expect(cell.highlightAlpha == 0)

    pointer = popUp.convert(inside, to: nil)

    popUp.mouseEntered(with: try crossing(.mouseEntered))
    draw(popUp)

    let hovered = cell.highlightAlpha

    cell.isMenuOpen = true

    #expect(hovered > 0 && cell.highlightAlpha == hovered)

    cell.isMenuOpen = false
    pointer = nil

    popUp.mouseExited(with: try crossing(.mouseExited))
    draw(popUp)

    #expect(cell.highlightAlpha == 0)
  }

  @Test(arguments: [true, false])
  func popUpShowsAtOnceWhenItsMenuClosesWhetherThePointerIsOverIt(pointerIsOver: Bool) throws {
    let popUp = ChoicePopUp(title: "CPU usage")
    let cell = try #require(popUp.cell as? ChoicePopUpCell)

    let window = NSWindow(
      contentRect: NSRect(x: -20_000, y: -20_000, width: 200, height: 40), styleMask: [], backing: .buffered,
      defer: false)

    func crossing(_ type: NSEvent.EventType) throws -> NSEvent {
      try #require(
        NSEvent.enterExitEvent(
          with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
          trackingNumber: 0, userData: nil))
    }

    popUp.show([2, 5], title: MetricsSettings.title(every:), selected: 2, offersOff: true)
    popUp.setFrameSize(popUp.intrinsicContentSize)
    window.contentView?.addSubview(popUp)
    window.orderFront(nil)

    defer { window.orderOut(nil) }

    let menu = try #require(popUp.menu)
    let pointer = popUp.convert(NSPoint(x: popUp.bounds.midX, y: popUp.bounds.midY), to: nil)

    #expect(menu.delegate === popUp)

    popUp.pointerLocation = { pointerIsOver ? pointer : nil }

    popUp.menuWillOpen(menu)

    #expect(cell.highlightAlpha == ChoicePopUpCell.highlightAlpha)

    cell.isHighlighted = true

    popUp.mouseExited(with: try crossing(.mouseExited))
    popUp.menuDidClose(menu)

    let expected: CGFloat = pointerIsOver ? ChoicePopUpCell.highlightAlpha : 0

    #expect(cell.highlightAlpha == expected)

    draw(popUp)

    #expect(cell.highlightAlpha == expected)
  }

  @Test func popUpShownTheSameChoicesAgainKeepsItsItems() {
    let popUp = ChoicePopUp(title: "CPU usage")

    popUp.show([2, 5], title: MetricsSettings.title(every:), selected: 2, offersOff: true)

    popUp.itemArray.first?.representedObject = "kept"

    popUp.show([2, 5], title: MetricsSettings.title(every:), selected: 5, offersOff: true)

    #expect(popUp.itemArray.first?.representedObject as? String == "kept")
    #expect(popUp.titleOfSelectedItem == "Every 5 seconds")

    popUp.show([2, 5], title: MetricsSettings.title(every:), selected: 7, offersOff: true)

    #expect(popUp.itemTitles.prefix(3) == ["Every 2 seconds", "Every 5 seconds", "Every 7 seconds"])
    #expect(popUp.titleOfSelectedItem == "Every 7 seconds")
  }

  @Test func popUpThatIsNotUnderThePointerAfterAChoiceIsNotHighlighted() throws {
    let settings = settingsWindow(PreferencesStore(defaults: TestDefaults().defaults))
    let metrics = try pane(MetricsSettings.self, in: settings)
    let gpu = try #require(metrics.intervals[.gpu])
    let cell = try #require(gpu.cell as? ChoicePopUpCell)

    settings.tabs.selectedTabViewItemIndex = 1
    gpu.pointerLocation = { gpu.convert(NSPoint(x: gpu.bounds.midX, y: gpu.bounds.midY), to: nil) }

    draw(gpu)

    #expect(cell.isHovered)

    gpu.pointerLocation = { nil }

    gpu.selectItem(withTag: 10)
    gpu.sendAction(gpu.action, to: gpu.target)

    #expect(gpu.needsDisplay)

    draw(gpu)

    #expect(!cell.isHovered)
  }

  @Test func secondClickOnAnInfoButtonClosesItsPopoverForGood() throws {
    let settings = settingsWindow(PreferencesStore(defaults: TestDefaults().defaults))
    let info = try #require(settings.panes[0].form.sections.compactMap(\.infoButton).first)

    func mouse(_ type: NSEvent.EventType, number: Int, at point: NSPoint) throws -> NSEvent {
      try #require(
        NSEvent.mouseEvent(
          with: type, location: info.convert(point, to: nil), modifierFlags: [], timestamp: 0,
          windowNumber: settings.window.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: 1))
    }

    let middle = NSPoint(x: info.bounds.midX, y: info.bounds.midY)

    info.noteClose(by: try mouse(.leftMouseDown, number: 7, at: middle))

    #expect(!info.opens(on: try mouse(.leftMouseUp, number: 7, at: middle)))
    #expect(info.opens(on: try mouse(.leftMouseUp, number: 8, at: middle)))

    info.noteClose(by: try mouse(.leftMouseDown, number: 9, at: NSPoint(x: -100, y: -100)))

    #expect(info.opens(on: try mouse(.leftMouseUp, number: 9, at: middle)))
  }

  @Test(arguments: [true, false])
  func popUpArrowsHaveTheSameRoomOnEverySideOfTheirBox(flipped: Bool) {
    let box = NSRect(x: 40, y: 3, width: 16, height: 16)
    let arrows = ChoicePopUpCell.arrows(in: box, flipped: flipped).bounds

    #expect(arrows.midX == box.midX && arrows.midY == box.midY)
    #expect(arrows.width < box.width && arrows.height < box.height)
  }

  @Test(arguments: [
    (1, "Every second"), (2, "Every 2 seconds"), (60, "Every minute"), (120, "Every 2 minutes"),
    (90, "Every 90 seconds"),
  ])
  func intervalIsSaidAsMailSaysHowOftenItChecks(seconds: Int, title: String) {
    #expect(MetricsSettings.title(every: seconds) == title)
  }

  @Test(arguments: [
    (40, "40 seconds"), (60, "1 minute"), (120, "2 minutes"), (5400, "1 hour 30 minutes"), (3601, "1 hour 1 second"),
  ])
  func spanIsSaidInWholeUnits(seconds: Int, span: String) {
    #expect(MetricsSettings.span(seconds: seconds) == span)
  }

  @Test func generalPaneSetsUnitsLowPowerBehaviorAndLaunchAtLoginAndRestoresDefaultsExceptLaunchAtLogin() throws {
    let preferences = PreferencesStore(defaults: TestDefaults().defaults)
    let service = FakeLoginItemService()

    let general = try pane(
      GeneralSettings.self, in: settingsWindow(preferences, loginItem: LoginItemManager(service: service)))

    general.unitControl.selectedSegment = 1

    general.unitControl.sendAction(general.unitControl.action, to: general.unitControl.target)

    general.lowPowerControl.selectedSegment = 1

    general.lowPowerControl.sendAction(general.lowPowerControl.action, to: general.lowPowerControl.target)
    general.loginSwitch.performClick(nil)

    #expect(preferences.preferences.temperatureUnit == .fahrenheit)
    #expect(preferences.preferences.lowPowerModeBehavior == .override)
    #expect(service.calls == ["register"])
    #expect(general.approvalRow.isHidden)

    service.status = .requiresApproval

    general.refreshLoginItem()

    #expect(!general.approvalRow.isHidden)

    #expect(
      general.approvalRow.titleField.attributedStringValue.size().width <= general.approvalRow.titleField.frame.width)

    general.restoreButton.performClick(nil)

    #expect(preferences.preferences == .standard)
    #expect(service.calls == ["register"])
    #expect(general.loginSwitch.state == .on)
    #expect(!general.approvalRow.isHidden)
    #expect(general.unitControl.selectedSegment == 0)
    #expect(general.lowPowerControl.selectedSegment == 0)
  }

  @Test func menuBarEditorEmptiesAWidgetWhoseMetricIsTurnedOffWhileSettingsIsOpen() throws {
    let editor = try pane(MenuBarSettings.self, in: settingsWindow(PreferencesStore(defaults: TestDefaults().defaults)))
      .editor

    let temperature = { editor.barView?.widgetViews.first { $0.widget == .temperature }?.content }

    coordinator.store.record(sample(value(50, .celsius), at: .now), for: .temperature)

    #expect(temperature() == .reading("50°", isStale: false))

    coordinator.disable(.temperature)

    #expect(temperature() == .noReading)
  }

  @Test func statusItemFollowsAChangeOfSettingsAtOnce() async throws {
    let details = DetailPopover(
      coordinator: coordinator, chip: .unrecognized(brandString: nil), temperatureUnit: .celsius)

    let controller = StatusItemController(
      store: coordinator.store, layout: .standard, temperatureUnit: .celsius, details: details)

    defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }

    let standardView = controller.menuBarView

    var preferences = Preferences.standard

    coordinator.store.record(sample(value(50, .celsius), at: .now), for: .temperature)
    await waitUntil { standardView.widgetViews.first?.content == .reading("50°", isStale: false) }
    controller.show(layout: preferences.shownMenuBarLayout, temperatureUnit: .celsius)

    #expect(controller.menuBarView === standardView)

    preferences.gpu.isEnabled = false

    controller.show(layout: preferences.shownMenuBarLayout, temperatureUnit: .fahrenheit)

    #expect(controller.menuBarView !== standardView)
    #expect(standardView.superview == nil)
    #expect(controller.menuBarView.widgetViews.map(\.widget) == [.temperature, .cpu, .memory])
    #expect(controller.menuBarView.widgetViews.first?.content == .reading("122°", isStale: false))
  }

  @Test func nearestWholeNumberInRangeIsTheClosestEndForAnythingOutside() {
    let range = 5...300

    #expect(range.nearest(to: 0) == 5)
    #expect(range.nearest(to: -1) == 5)
    #expect(range.nearest(to: 12.4) == 12)
    #expect(range.nearest(to: 1e300) == 300)
    #expect(range.nearest(to: .infinity) == 300)
    #expect(range.nearest(to: -.infinity) == 5)
    #expect(range.nearest(to: .nan) == nil)
  }
}

struct SplitMix64: RandomNumberGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15

    var z = state

    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB

    return z ^ (z >> 31)
  }
}

final class Target: NSObject {
  var fired = 0

  @objc func fire() {
    fired += 1
  }
}

final class FakeLoginItemService: LoginItemService {
  var status = SMAppService.Status.notRegistered
  var failure: SensorError?
  var calls: [String] = []

  func register() throws {
    if let failure { throw failure }

    calls.append("register")

    status = .enabled
  }

  func unregister() throws {
    if let failure { throw failure }

    calls.append("unregister")

    status = .notRegistered
  }
}

@MainActor
func draw(_ view: NSView) {
  guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }

  view.cacheDisplay(in: view.bounds, to: bitmap)
}
