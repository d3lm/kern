import AppKit
import KernCore

final class MenuBarView: NSView {
  let widgetViews: [WidgetView]
  /// Shows Kern's symbol when the layout shows no widget, so the item can still be clicked to reach the settings.
  let placeholder: NSImageView?

  /// Asks the owner to show a metric again, which each widget does at its `onStaleDeadline`.
  var onStaleDeadline: (Metric) -> Void = { _ in }

  private let spacing: CGFloat
  private let height: CGFloat

  init(layout: MenuBarLayout, temperatureUnit: TemperatureUnit, style: MenuBarStyle = MenuBarStyle()) {
    widgetViews = layout.widgets.map { widget in
      WidgetView(
        widget: widget, label: layout.label(of: widget), temperatureUnit: temperatureUnit, style: style)
    }

    placeholder = widgetViews.isEmpty ? Self.placeholder(style: style) : nil
    spacing = style.widgetSpacing
    height = style.height

    super.init(frame: NSRect(x: 0, y: 0, width: 0, height: style.height))

    for view in widgetViews {
      addSubview(view)

      view.onContentWidthChange = { [weak self] in self?.widthsChanged() }
      view.onStaleDeadline = { [weak self, metric = view.widget.metric] in self?.onStaleDeadline(metric) }
    }

    if let placeholder {
      addSubview(placeholder)
    }

    setFrameSize(intrinsicContentSize)
    layOutWidgets()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("MenuBarView is not loaded from a nib")
  }

  private static func placeholder(style: MenuBarStyle) -> NSImageView {
    let image = NSImage(systemSymbolName: style.placeholderSymbol, accessibilityDescription: nil) ?? NSImage()
    let view = NSImageView(image: image)

    view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: style.placeholderPointSize, weight: .regular)
    view.contentTintColor = .labelColor

    view.sizeToFit()

    return view
  }

  func show(_ readings: MetricReadings, for metric: Metric) {
    for view in widgetViews where view.widget.metric == metric {
      view.show(readings)
    }
  }

  private var widths: [CGFloat] {
    widgetViews.indices.map { index in
      index == 0 ? widgetViews[index].contentWidth : widgetViews[index].widestWidth
    }
  }

  override var intrinsicContentSize: NSSize {
    if let placeholder {
      return NSSize(width: placeholder.frame.width, height: height)
    }

    return NSSize(width: widths.reduce(0, +) + spacing * CGFloat(widgetViews.count - 1), height: height)
  }

  override func layout() {
    super.layout()
    layOutWidgets()
  }

  private func layOutWidgets() {
    placeholder?.setFrameOrigin(NSPoint(x: 0, y: ((height - (placeholder?.frame.height ?? 0)) / 2).rounded()))

    for (view, frame) in zip(widgetViews, layoutFrames) {
      view.frame = frame
    }
  }

  /// Returns where the layout puts each widget, which differs from its frame while the widget slides there.
  var layoutFrames: [NSRect] {
    var x: CGFloat = 0

    return widths.map { width in
      defer { x += width + spacing }

      return NSRect(x: x, y: 0, width: width, height: height)
    }
  }

  private func widthsChanged() {
    invalidateIntrinsicContentSize()
    layOutWidgets()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}
