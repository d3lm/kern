import AppKit
import KernCore

final class MenuBarView: NSView {
  let widgetViews: [WidgetView]

  /// Asks the owner to show a metric again, which each widget does at its `onStaleDeadline`.
  var onStaleDeadline: (Metric) -> Void = { _ in }

  private let spacing: CGFloat
  private let height: CGFloat

  init(layout: MenuBarLayout, style: MenuBarStyle = MenuBarStyle()) {
    widgetViews = layout.widgets.map { widget in
      WidgetView(widget: widget, label: layout.showsLabels ? widget.label : nil, style: style)
    }
    spacing = style.widgetSpacing
    height = style.height

    super.init(frame: NSRect(x: 0, y: 0, width: 0, height: style.height))

    for view in widgetViews {
      addSubview(view)
      view.onContentWidthChange = { [weak self] in self?.widthsChanged() }
      view.onStaleDeadline = { [weak self, metric = view.widget.metric] in self?.onStaleDeadline(metric) }
    }

    setFrameSize(intrinsicContentSize)
    layOutWidgets()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("MenuBarView is not loaded from a nib")
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
    NSSize(width: widths.reduce(0, +) + spacing * CGFloat(widgetViews.count - 1), height: height)
  }

  override func layout() {
    super.layout()
    layOutWidgets()
  }

  private func layOutWidgets() {
    var x: CGFloat = 0

    for (view, width) in zip(widgetViews, widths) {
      view.frame = NSRect(x: x, y: 0, width: width, height: height)
      x += width + spacing
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
