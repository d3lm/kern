import AppKit
import KernCore
import os

private let logger = Logger(subsystem: "Kern", category: "popover")
private let signposter = OSSignposter(subsystem: "Kern", category: "popover")

@MainActor
final class DetailPopover {
  private struct Open {
    let panel: DetailPanel
    let content: DetailView
    let button: NSButton
    let observer: MetricsStore.ObserverID
    let monitors: [Any]
  }

  private let coordinator: MetricsCoordinator<ContinuousClock>
  private let sources: [Metric: MetricSource]
  private let chip: String?
  private let style = DetailStyle()
  private var open: Open?

  init(coordinator: MetricsCoordinator<ContinuousClock>, chip: ChipIdentity) {
    self.coordinator = coordinator
    self.sources = Dictionary(uniqueKeysWithValues: Metric.allCases.map { ($0, coordinator.source(of: $0)) })
    self.chip = chip.name
  }

  var isShown: Bool { open != nil }
  var content: DetailView? { open?.content }

  func toggle(from button: NSButton) {
    if open == nil {
      show(from: button)
    } else {
      close()
    }
  }

  func show(from button: NSButton) {
    guard open == nil else { return }

    let interval = signposter.beginInterval("open popover")
    let start = ContinuousClock.now
    let store = coordinator.store
    let content = DetailView(sources: sources, chip: chip, style: style)
    let panel = DetailPanel(content: content, style: style)

    coordinator.areDetailsVisible = true

    for metric in Metric.allCases {
      if let readings = store[metric] {
        content.show(readings, for: metric)
      }
    }

    content.fittingSizeChanged = { [weak self] in self?.place(below: button) }

    let observer = store.observe { [weak content] metric in
      if let readings = store[metric] {
        content?.show(readings, for: metric)
      }
    }

    open = Open(
      panel: panel,
      content: content,
      button: button,
      observer: observer,
      monitors: monitors(closingOnClicksOutside: panel, and: button)
    )

    place(below: button)
    panel.orderFrontRegardless()
    button.highlight(true)

    // without the flush, the signpost interval ends before the panel is laid out and drawn
    CATransaction.flush()

    signposter.endInterval("open popover", interval)
    logger.debug("opened popover in \(ContinuousClock.now - start, privacy: .public)")
  }

  func close() {
    guard let open else { return }

    self.open = nil

    for monitor in open.monitors {
      NSEvent.removeMonitor(monitor)
    }

    coordinator.store.removeObserver(open.observer)
    coordinator.areDetailsVisible = false
    open.panel.orderOut(nil)
    open.panel.contentView = nil
    open.button.highlight(false)

    // malloc keeps freed pages, which count as Kern's memory, until memory pressure, so every close returns them
    malloc_zone_pressure_relief(nil, 0)

    logger.debug("closed popover")
  }

  private func place(below button: NSButton) {
    guard let open, let itemFrame = button.window?.frame else { return }

    let size = open.content.fittingSize
    var origin = NSPoint(x: itemFrame.midX - size.width / 2, y: itemFrame.minY - style.panelGap - size.height)

    if let screen = button.window?.screen?.visibleFrame {
      origin.x = min(max(origin.x, screen.minX + style.screenMargin), screen.maxX - style.screenMargin - size.width)
    }

    let frame = NSRect(origin: origin, size: size)

    if frame != open.panel.frame {
      open.panel.setFrame(frame, display: true)
      open.panel.invalidateShadow()
    }
  }

  /// Clicks on the item are left to its action, which closes the panel. Closing here too would reopen it.
  private func monitors(closingOnClicksOutside panel: NSPanel, and button: NSButton) -> [Any] {
    let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

    let inKern = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self, weak panel, weak button] event in
      if event.window !== panel && event.window !== button?.window {
        MainActor.assumeIsolated { self?.close() }
      }

      return event
    }

    let inOtherApps = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
      MainActor.assumeIsolated { self?.close() }
    }

    return [inKern, inOtherApps].compactMap { $0 }
  }
}

private final class DetailPanel: NSPanel {
  init(content: NSView, style: DetailStyle) {
    super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)

    isFloatingPanel = true
    level = .popUpMenu
    backgroundColor = .clear
    isOpaque = false
    hasShadow = true
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    animationBehavior = .none
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

    let background = NSVisualEffectView()
    let outline = PanelOutline(cornerRadius: style.panelCornerRadius)

    background.material = .popover
    background.state = .active
    background.blendingMode = .behindWindow
    background.maskImage = Self.mask(cornerRadius: style.panelCornerRadius)

    contentView = background

    for view in [content, outline] {
      view.frame = background.bounds
      view.autoresizingMask = [.width, .height]
      background.addSubview(view)
    }
  }

  private static func mask(cornerRadius radius: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: 2 * radius + 1, height: 2 * radius + 1), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

      return true
    }

    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch

    return image
  }
}

/// The panel is too large to draw without AppKit switching to Metal, so its outline is a layer border.
private final class PanelOutline: NSView {
  private let cornerRadius: CGFloat

  init(cornerRadius: CGFloat) {
    self.cornerRadius = cornerRadius

    super.init(frame: .zero)

    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("PanelOutline is not loaded from a nib")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    guard let layer else { return }

    layer.cornerRadius = cornerRadius
    layer.borderWidth = 1
    layer.borderColor = NSColor.labelColor.withAlphaComponent(0.15).cgColor
  }
}
