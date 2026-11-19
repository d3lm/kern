import AppKit
import KernCore
import ServiceManagement

/// Is a tab of the Settings window. It shows the preferences it is given and changes them through the store, which
/// passes every change back to `show(_:)`.
@MainActor
class SettingsPane: NSViewController {
  let preferences: PreferencesStore
  let style = SettingsStyle()
  private(set) var form = SettingsForm([], style: SettingsStyle())

  init(_ title: String, preferences: PreferencesStore) {
    self.preferences = preferences

    super.init(nibName: nil, bundle: nil)

    self.title = title
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("SettingsPane is not loaded from a nib")
  }

  /// The tab view controller turns the selected tab's `preferredContentSize` into a constraint that outranks the
  /// window's own size, so the window follows a tab whose height changes while it is shown.
  func makeForm(_ sections: [SettingsSection]) {
    form = SettingsForm(sections, style: style)
    form.sizeChanged = { [weak self] size in self?.preferredContentSize = size }
    view = form
    preferredContentSize = form.size
  }

  func show(_ preferences: Preferences) {}

  /// Ends what the pane does while the window is open.
  func stop() {}
}

final class GeneralSettings: SettingsPane {
  let loginSwitch = NSSwitch()
  let approvalRow: SettingsRow
  let failureRow: SettingsRow
  let unitControl = SlidingSegmentedControl(labels: ["°C", "°F"])
  let lowPowerControl = SlidingSegmentedControl(labels: ["Adaptive", "Keep intervals"])
  let restoreButton = NSButton(title: "Restore Defaults", target: nil, action: nil)
  private let loginItem: LoginItemManager

  init(preferences: PreferencesStore, loginItem: LoginItemManager) {
    self.loginItem = loginItem

    let style = SettingsStyle()
    let openLoginItems = NSButton(title: "Open Login Items", target: nil, action: nil)

    approvalRow = SettingsRow("Waiting for your approval", accessories: [openLoginItems], style: style)
    failureRow = SettingsRow("", accessories: [], style: style)

    super.init("General", preferences: preferences)

    loginSwitch.configureForSettings(target: self, action: #selector(toggleLogin))

    openLoginItems.target = self
    openLoginItems.action = #selector(openLoginItemsSettings)
    approvalRow.titleField.textColor = .secondaryLabelColor
    failureRow.titleField.textColor = .systemRed

    unitControl.setAccessibilityLabel("Temperature unit")
    lowPowerControl.setAccessibilityLabel("When Low Power Mode is on")

    for control in [unitControl, lowPowerControl] {
      control.target = self
      control.action = #selector(choose(_:))
    }

    restoreButton.target = self
    restoreButton.action = #selector(restoreDefaults)

    makeForm([
      SettingsSection(
        "Startup",
        rows: [SettingsRow("Launch at login", accessories: [loginSwitch], style: style), approvalRow, failureRow],
        style: style),
      SettingsSection(
        "Units", rows: [SettingsRow("Temperature", accessories: [unitControl], style: style)], style: style),
      SettingsSection(
        "Low Power Mode",
        info: "Adaptive samples less often to save energy. CPU and GPU are sampled at most every 5 seconds, memory "
          + "every 10, and temperature every 20.",
        rows: [SettingsRow("When Low Power Mode is on", accessories: [lowPowerControl], style: style)],
        footer: [restoreButton],
        style: style),
    ])

    show(preferences.preferences)
    showLoginItem()
  }

  override func show(_ preferences: Preferences) {
    unitControl.selectedSegment = TemperatureUnit.allCases.firstIndex(of: preferences.temperatureUnit) ?? 0
    lowPowerControl.selectedSegment = preferences.lowPowerModeBehavior == .adaptive ? 0 : 1
  }

  /// Asks macOS again, because the user can change launch at login in System Settings too.
  func refreshLoginItem() {
    loginItem.refresh()
    showLoginItem()
  }

  private func showLoginItem() {
    loginSwitch.state = loginItem.isEnabled ? .on : .off
    approvalRow.isHidden = loginItem.status != .requiresApproval
    failureRow.isHidden = loginItem.failure == nil
    failureRow.titleField.stringValue = loginItem.failure ?? ""
    failureRow.toolTip = loginItem.failure

    form.arrange()
  }

  @objc private func toggleLogin() {
    loginItem.setEnabled(loginSwitch.state == .on)
    showLoginItem()
  }

  @objc private func openLoginItemsSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  @objc private func choose(_ sender: SlidingSegmentedControl) {
    let index = sender.selectedSegment

    preferences.update { preferences in
      if sender === unitControl {
        preferences.temperatureUnit = TemperatureUnit.allCases[index]
      } else {
        preferences.lowPowerModeBehavior = index == 0 ? .adaptive : .override
      }
    }
  }

  /// Leaves launch at login as it is, because macOS keeps it and the user may have set it in System Settings.
  @objc private func restoreDefaults() {
    preferences.restoreDefaults()
  }
}

final class MetricsSettings: SettingsPane {
  let intervals: [Monitor: ChoicePopUp]
  let graphSamples = ChoicePopUp(title: "Graph samples")
  let graphRow: SettingsRow
  private(set) var customEditor: CustomValueEditor?
  private let store: MetricsStore
  private var observer: MetricsStore.ObserverID?

  init(preferences: PreferencesStore, store: MetricsStore) {
    let style = SettingsStyle()
    let intervals = Dictionary(uniqueKeysWithValues: Monitor.allCases.map { ($0, ChoicePopUp(title: $0.title)) })

    self.intervals = intervals
    self.store = store
    graphRow = SettingsRow("Graph samples", subtitle: "", accessories: [graphSamples], style: style)

    super.init("Metrics", preferences: preferences)

    for (monitor, popUp) in intervals {
      popUp.onChoice = { [weak self] choice in
        self?.preferences.update { preferences in
          if choice == ChoicePopUp.off {
            preferences[monitor].isEnabled = false
          } else {
            preferences[monitor] = MonitorSettings(isEnabled: true, interval: choice)
          }
        }
      }

      popUp.onCustom = { [weak self, weak popUp] in
        guard let self, let popUp else { return }

        editCustom(
          preferences.preferences[monitor].interval, range: monitor.intervals, unit: "seconds",
          title: "\(monitor.title) interval", below: popUp
        ) { [weak self] interval in
          self?.preferences.update { $0[monitor] = MonitorSettings(isEnabled: true, interval: interval) }
        }
      }
    }

    graphSamples.onChoice = { [weak self] count in self?.preferences.update { $0.graphSamples = count } }

    graphSamples.onCustom = { [weak self] in
      guard let self else { return }

      editCustom(
        preferences.preferences.graphSamples, range: Preferences.graphSampleCounts, unit: "samples",
        title: "Graph samples", below: graphSamples
      ) { [weak self] count in
        self?.preferences.update { $0.graphSamples = count }
      }
    }

    makeForm([
      SettingsSection(
        "Sampling",
        info: "A metric that is off is not sampled, and its widget leaves the menu bar. Used memory is read only "
          + "while the details are open.",
        rows: Monitor.allCases.compactMap { monitor in
          intervals[monitor].map { SettingsRow(monitor.title, accessories: [$0], style: style) }
        },
        style: style),
      SettingsSection("History", rows: [graphRow], style: style),
    ])

    showCPUChartSpan()
    show(preferences.preferences)

    observer = store.observe { [weak self] metric in
      if metric == .cpu { self?.showCPUChartSpan() }
    }
  }

  override func show(_ preferences: Preferences) {
    for (monitor, popUp) in intervals {
      let settings = preferences[monitor]

      popUp.show(
        monitor.intervalChoices, title: Self.title(every:),
        selected: settings.isEnabled ? settings.interval : ChoicePopUp.off, offersOff: true)
    }

    graphSamples.show(
      Self.sampleCounts, title: { "\($0) samples" }, selected: preferences.graphSamples, offersOff: false)

    form.arrange()
  }

  override func stop() {
    customEditor?.popover.close()

    if let observer { store.removeObserver(observer) }

    observer = nil
  }

  /// Reads the span from the store, because Adaptive stretches the CPU interval while Low Power Mode is on.
  private func showCPUChartSpan() {
    guard let readings = store[.cpu], let capacity = readings.history?.capacity else { return }

    let seconds = Int((readings.interval * capacity).components.seconds)
    let subtitle = "The CPU chart shows the last \(Self.span(seconds: seconds))."

    if subtitle != graphRow.subtitle { graphRow.subtitle = subtitle }
  }

  private func editCustom(
    _ value: Int, range: ClosedRange<Int>, unit: String, title: String, below popUp: NSView,
    onApply: @escaping (Int) -> Void
  ) {
    customEditor?.popover.close()

    let editor = CustomValueEditor(value: value, range: range, unit: unit, title: title, onApply: onApply)

    customEditor = editor

    editor.show(below: popUp)
  }

  static let sampleCounts = [20, 30, 60, 90, 120, 180, 240]

  static func title(every seconds: Int) -> String {
    switch seconds {
    case 1: "Every second"
    case 60: "Every minute"
    case let minutes where minutes.isMultiple(of: 60): "Every \(minutes / 60) minutes"
    default: "Every \(seconds) seconds"
    }
  }

  /// Says a span as "2 minutes" or "1 hour 30 minutes".
  static func span(seconds: Int) -> String {
    let parts = [(seconds / 3600, "hour"), (seconds % 3600 / 60, "minute"), (seconds % 60, "second")]

    return parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }.joined(separator: " ")
  }
}

final class MenuBarSettings: SettingsPane {
  let editor: MenuBarEditor
  let labelSwitches: [Widget: NSSwitch]

  init(preferences: PreferencesStore, store: MetricsStore) {
    let style = SettingsStyle()

    let labeled = Widget.allCases.filter { $0.label != nil }

    editor = MenuBarEditor(store: store, style: style)
    labelSwitches = Dictionary(uniqueKeysWithValues: labeled.map { ($0, NSSwitch()) })

    super.init("Menu Bar", preferences: preferences)

    for (widget, labelSwitch) in labelSwitches {
      labelSwitch.configureForSettings(target: self, action: #selector(toggleLabel(_:)))
      labelSwitch.setAccessibilityLabel("\(widget.title) label")
    }

    editor.onLayoutChange = { [weak self] layout in self?.preferences.update { $0.menuBarLayout = layout } }
    editor.onHeightChange = { [weak self] in self?.form.arrange() }

    makeForm([
      SettingsSection(
        "Menu Bar",
        info: "Drag a widget to move it, or drag it out of the menu bar to remove it. Drag a widget from Available "
          + "into the menu bar to add it. A right-click on a widget does the same. CPU cores shows the usage of "
          + "each core. Storage shows how full the startup disk is, and Kern usage shows the CPU and memory Kern "
          + "itself uses. Kern measures these two only while their widget is in the menu bar or this window is open.",
        content: editor, style: style),
      SettingsSection(
        "Labels",
        rows: labeled.compactMap { widget in
          labelSwitches[widget].map { SettingsRow(widget.title, accessories: [$0], style: style) }
        },
        style: style),
    ])

    show(preferences.preferences)
  }

  override func show(_ preferences: Preferences) {
    editor.show(preferences)

    for (widget, labelSwitch) in labelSwitches {
      labelSwitch.state = preferences.menuBarLayout.label(of: widget) != nil ? .on : .off
    }

    form.arrange()
  }

  override func stop() {
    editor.stop()
  }

  @objc private func toggleLabel(_ sender: NSSwitch) {
    guard let widget = labelSwitches.first(where: { $0.value === sender })?.key else { return }

    preferences.update { $0.menuBarLayout.setShowsLabel(sender.state == .on, widget) }
  }
}

extension Monitor {
  var title: String {
    switch self {
    case .cpu: "CPU usage"
    case .gpu: "GPU activity"
    case .temperature: "Temperature"
    case .memory: "Memory"
    }
  }

  var intervalChoices: [Int] {
    let choices =
      switch self {
      case .cpu, .gpu: [2, 3, 5, 10, 15, 30, 60]
      case .temperature: [5, 10, 15, 30, 60, 120, 300]
      case .memory: [2, 5, 10, 15, 30, 60, 120, 300]
      }

    return choices.filter(intervals.contains)
  }
}

extension Widget {
  var title: String {
    switch self {
    case .temperature: "Temperature"
    case .cpu: "CPU"
    case .cores: "CPU cores"
    case .gpu: "GPU"
    case .memory: "Memory"
    case .storage: "Storage"
    case .kern: "Kern usage"
    }
  }
}
