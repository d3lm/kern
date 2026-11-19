import AppKit
import KernCore
import os

private let logger = Logger(subsystem: "Kern", category: "menu bar")

@MainActor
final class StatusItemController: NSObject {
  private static let padding: CGFloat = 8
  /// Must outlast the spread of about 15 ms between the samples of one tick, so that a tick is drawn in one pass.
  static let batchWindow = Duration.milliseconds(50)

  private let store: MetricsStore
  let statusItem: NSStatusItem
  private(set) var menuBarView: MenuBarView
  private var layout: MenuBarLayout
  private var temperatureUnit: TemperatureUnit
  private let details: DetailPopover
  private let openSettings: @MainActor () -> Void
  private lazy var menu = Self.menu(settingsTarget: self, settingsAction: #selector(chooseSettings))
  private var mouseDowns: MouseDownMonitor?
  private var batch: SampleBatch?

  /// Shows the widgets of `layout`, which must hide the widgets of metrics that are turned off.
  init(
    store: MetricsStore,
    layout: MenuBarLayout,
    temperatureUnit: TemperatureUnit,
    details: DetailPopover,
    openSettings: @escaping @MainActor () -> Void = {}
  ) {
    self.store = store
    self.layout = layout
    self.temperatureUnit = temperatureUnit
    self.details = details
    self.openSettings = openSettings
    self.menuBarView = MenuBarView(layout: layout, temperatureUnit: temperatureUnit)
    self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    super.init()

    guard let button = statusItem.button else { preconditionFailure("a status item made by the system has a button") }

    button.setAccessibilityLabel("Kern")

    // the action still handles presses that are not mouse clicks, such as VoiceOver's
    mouseDowns = MouseDownMonitor(on: button) { [weak self] event in self?.click(button, with: event) }
    button.target = self
    button.action = #selector(press(_:))

    install(menuBarView, in: button)

    let batch = SampleBatch(window: Self.batchWindow) { [weak self] metrics in
      for metric in metrics {
        self?.show(metric)
      }
    }

    self.batch = batch

    _ = store.observe { metric in batch.add(metric) }
  }

  func show(layout: MenuBarLayout, temperatureUnit: TemperatureUnit) {
    guard layout != self.layout || temperatureUnit != self.temperatureUnit, let button = statusItem.button else {
      return
    }

    self.layout = layout
    self.temperatureUnit = temperatureUnit

    menuBarView.removeFromSuperview()

    menuBarView = MenuBarView(layout: layout, temperatureUnit: temperatureUnit)

    install(menuBarView, in: button)
  }

  private func install(_ view: MenuBarView, in button: NSStatusBarButton) {
    button.addSubview(view)

    // a fixed-length item jumps by its inset when Command-dragged, and a changed button image makes the menu bar
    // redraw its shadow for every display, so the item is variable-length and sized by these constraints
    view.translatesAutoresizingMaskIntoConstraints = false

    view.setContentHuggingPriority(.required, for: .horizontal)
    view.setContentCompressionResistancePriority(.required, for: .horizontal)

    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: Self.padding),
      view.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -Self.padding),
      view.centerYAnchor.constraint(equalTo: button.centerYAnchor),
    ])

    let widgets = layout.widgets.map(\.rawValue).joined(separator: ", ")
    let labeled = layout.widgets.filter { layout.label(of: $0) != nil }.map(\.rawValue).joined(separator: ", ")
    let labels = labeled.isEmpty ? "without labels" : "with labels on \(labeled)"

    logger.debug("showing \(widgets, privacy: .public), \(labels, privacy: .public)")

    view.onStaleDeadline = { [weak self] metric in self?.show(metric) }

    showAll()
  }

  private func showAll() {
    for metric in Metric.allCases {
      show(metric)
    }
  }

  private func show(_ metric: Metric) {
    guard let readings = store[metric] else { return }

    menuBarView.show(readings, for: metric)
  }

  /// The button clears its highlight when the press ends, after sending the action, so the panel opens afterwards
  /// to keep the highlight.
  @objc private func press(_ sender: NSStatusBarButton) {
    DispatchQueue.main.async { [weak self] in
      self?.details.toggle(from: sender)
    }
  }

  @objc private func chooseSettings() {
    openSettings()
  }

  private func click(_ button: NSStatusBarButton, with event: NSEvent) {
    if Self.isMenuClick(event) {
      details.close()
      showMenu(below: button)
    } else {
      details.toggle(from: button)
    }
  }

  /// A menu the status item shows itself is at least as wide as the item, so the menu pops up from the button
  /// instead, which keeps it as wide as its items. `popUp` puts the menu's frame 5 points above the point it is
  /// given, and the offset puts it where the status item would, 4 points left of the button and against the bottom
  /// of the menu bar. It returns once the menu has closed.
  private func showMenu(below button: NSStatusBarButton) {
    button.highlight(true)
    menu.popUp(positioning: nil, at: NSPoint(x: -4, y: button.bounds.maxY + 7), in: button)
    button.highlight(false)
  }

  static func menu(settingsTarget: AnyObject, settingsAction: Selector) -> NSMenu {
    let menu = NSMenu()
    let settings = NSMenuItem(title: "Settings…", action: settingsAction, keyEquivalent: ",")
    let quit = NSMenuItem(title: "Quit Kern", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    settings.target = settingsTarget
    quit.target = NSApp

    menu.addItem(settings)
    menu.addItem(.separator())
    menu.addItem(quit)

    return menu
  }

  nonisolated static func isMenuClick(_ event: NSEvent) -> Bool {
    event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
  }
}
