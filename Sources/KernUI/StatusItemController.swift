import AppKit
import KernCore
import os

private let logger = Logger(subsystem: "Kern", category: "menu bar")

/// Kern's menu-bar item. It passes each new sample to the widgets, and its menu offers Quit until the popover
/// replaces it in Phase 7.
@MainActor
final class StatusItemController {
  /// The space the menu bar leaves on each side of a status item's image.
  private static let padding: CGFloat = 8
  /// Long enough for the slowest sensor's sample from the same tick, which arrives about 15 ms after the fastest,
  /// and short enough to keep a sample's way to the screen well under the 100 ms that PRD §5.1 allows.
  private static let batchWindow = Duration.milliseconds(50)

  private let store: MetricsStore
  private let statusItem: NSStatusItem
  private let menuBarView: MenuBarView
  private var batch: SampleBatch?

  init(store: MetricsStore, layout: MenuBarLayout) {
    self.store = store
    self.menuBarView = MenuBarView(layout: layout)
    self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    guard let button = statusItem.button else { preconditionFailure("a status item made by the system has a button") }

    button.setAccessibilityLabel("Kern")
    button.addSubview(menuBarView)

    // A variable-length item sized by its content fills its window, as the system's items do; a fixed-length
    // item sits inset in its window and jumps by the inset when a Command-drag picks it up. The size comes from
    //  constraints, not from a button image, because a changed button image makes the menu bar blur a new shadow
    // for each display.
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

    let menu = NSMenu()

    menu.addItem(withTitle: "Quit Kern", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    statusItem.menu = menu

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
}
