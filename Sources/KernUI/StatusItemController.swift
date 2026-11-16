import AppKit
import KernCore
import os

private let logger = Logger(subsystem: "Kern", category: "menu bar")

@MainActor
final class StatusItemController: NSObject {
  private static let padding: CGFloat = 8
  /// Must outlast the spread of about 15 ms between the samples of one tick, so that a tick is drawn in one pass.
  private static let batchWindow = Duration.milliseconds(50)

  private let store: MetricsStore
  let statusItem: NSStatusItem
  let menuBarView: MenuBarView
  private let details: DetailPopover
  private let menu = NSMenu()
  private var mouseDowns: MouseDownMonitor?
  private var batch: SampleBatch?

  init(store: MetricsStore, layout: MenuBarLayout, details: DetailPopover) {
    self.store = store
    self.details = details
    self.menuBarView = MenuBarView(layout: layout)
    self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    super.init()

    guard let button = statusItem.button else { preconditionFailure("a status item made by the system has a button") }

    button.setAccessibilityLabel("Kern")
    button.addSubview(menuBarView)

    // the action still handles presses that are not mouse clicks, such as VoiceOver's
    mouseDowns = MouseDownMonitor(on: button) { [weak self] event in self?.click(button, with: event) }
    button.target = self
    button.action = #selector(press(_:))

    let quit = NSMenuItem(title: "Quit Kern", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    quit.target = NSApp
    menu.addItem(quit)

    // a fixed-length item jumps by its inset when Command-dragged, and a changed button image makes the menu bar
    // redraw its shadow for every display, so the item is variable-length and sized by these constraints
    menuBarView.translatesAutoresizingMaskIntoConstraints = false
    menuBarView.setContentHuggingPriority(.required, for: .horizontal)
    menuBarView.setContentCompressionResistancePriority(.required, for: .horizontal)

    NSLayoutConstraint.activate([
      menuBarView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: Self.padding),
      menuBarView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -Self.padding),
      menuBarView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
    ])

    let widgets = layout.widgets.map(\.rawValue).joined(separator: ", ")

    logger.debug(
      "showing \(widgets, privacy: .public), \(layout.showsLabels ? "with" : "without", privacy: .public) labels")

    for metric in Metric.allCases {
      show(metric)
    }

    let batch = SampleBatch(window: Self.batchWindow) { [weak self] metrics in
      for metric in metrics {
        self?.show(metric)
      }
    }

    self.batch = batch

    _ = store.observe { metric in
      logger.debug("\(metric.rawValue, privacy: .public) sample arrived")

      batch.add(metric)
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

  /// An item with a menu shows it on every click instead of sending its action, so the menu is attached only while
  /// it is shown.
  private func click(_ button: NSStatusBarButton, with event: NSEvent) {
    if Self.isMenuClick(event) {
      details.close()
      statusItem.menu = menu
      button.performClick(nil)
      statusItem.menu = nil
    } else {
      details.toggle(from: button)
    }
  }

  nonisolated static func isMenuClick(_ event: NSEvent) -> Bool {
    event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
  }
}
