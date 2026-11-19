import AppKit
import KernCore
import os

private let logger = Logger(subsystem: "Kern", category: "menu bar")

final class WidgetView: NSView {
  let widget: Widget
  let temperatureUnit: TemperatureUnit
  /// Holds the width the widget needs, which follows the text it shows and the number of its bars, and is fixed
  /// for a chart or a gauge alone.
  private(set) var contentWidth: CGFloat
  var onContentWidthChange: () -> Void = {}

  /// Asks the owner to show the metric's readings again at the moment the value shown would go stale.
  /// The view keeps no readings to check itself, because a copy of a history would make the store copy
  /// it on its next sample.
  var onStaleDeadline: () -> Void = {}

  private let style: MenuBarStyle
  private let labelLetters: [TextLine]
  private let valueOffset: CGFloat
  private(set) var content: WidgetContent?
  private var valueLines: [TextLine] = []
  private lazy var staleCheck = StaleCheck { [weak self] in self?.onStaleDeadline() }
  private(set) var drawCount = 0

  init(widget: Widget, label: String?, temperatureUnit: TemperatureUnit, style: MenuBarStyle) {
    self.widget = widget
    self.temperatureUnit = temperatureUnit
    self.style = style
    self.labelLetters = label.map { $0.map { TextLine(String($0), font: style.labelFont) } } ?? []
    self.valueOffset = style.valueOffset(label: label)
    self.contentWidth = style.width(of: widget, label: label)

    super.init(frame: NSRect(x: 0, y: 0, width: contentWidth, height: style.height))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("WidgetView is not loaded from a nib")
  }

  func show(_ readings: MetricReadings) {
    let content = widget.content(for: readings, at: .now, temperatureUnit: temperatureUnit)

    render(content)

    staleCheck.schedule(at: content.isStale ? nil : readings.staleAt)
  }

  private func render(_ content: WidgetContent) {
    guard content != self.content else { return }

    valueLines =
      switch content {
      case .reading(let text, _): [TextLine(text, font: style.valueFont)]
      case .noReading: [TextLine(WidgetContent.unavailableText, font: style.valueFont)]
      case .stacked(let top, let bottom, _): [top, bottom].map { TextLine($0, font: style.stackedFont) }
      case .levelReading(.percent(let percent), _): [TextLine("\(percent)%", font: style.valueFont)]
      case .level, .levelReading, .graph, .bars: []
      }

    let contentWidth = valueOffset + valueWidth(of: content)

    if contentWidth != self.contentWidth {
      self.contentWidth = contentWidth

      onContentWidthChange()
    }

    self.content = content
    needsDisplay = true

    logger.debug("redraw \(self.widget.rawValue, privacy: .public): \(content, privacy: .public)")
  }

  private func valueWidth(of content: WidgetContent) -> CGFloat {
    let textWidth = ceil(valueLines.map(\.width).max() ?? 0)

    return switch content {
    case .reading, .noReading, .stacked: textWidth
    case .levelReading: style.gaugeWidth + (valueLines.isEmpty ? 0 : style.gaugeTextSpacing + textWidth)
    case .bars(let levels, _): style.coresWidth(count: levels.count)
    case .level, .graph: style.valueWidth(of: widget)
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    drawCount += 1

    guard let content, let context = NSGraphicsContext.current?.cgContext else { return }

    let pixel = 1 / max(1, abs(context.userSpaceToDeviceSpaceTransform.d))
    let valueAlpha = content.isStale ? style.staleAlpha : style.valueAlpha
    let value = NSRect(x: valueOffset, y: 0, width: bounds.width - valueOffset, height: bounds.height)

    context.textMatrix = .identity

    drawLabel(in: context, pixel: pixel)

    switch content {
    case .reading:
      drawLines(valueLines, font: style.valueFont, alignedRightIn: value, alpha: valueAlpha, in: context, pixel: pixel)
    case .stacked:
      drawLines(
        valueLines, font: style.stackedFont, alignedRightIn: value, alpha: valueAlpha, in: context, pixel: pixel)
    case .noReading:
      drawCentered(valueLines[0], in: value, alpha: valueAlpha, in: context, pixel: pixel)
    case .level(let level, _):
      drawGauge(level, in: value, alpha: valueAlpha, pixel: pixel)
    case .levelReading(let level, _):
      drawGauge(level, in: value, alpha: valueAlpha, pixel: pixel)
      drawLines(valueLines, font: style.valueFont, alignedRightIn: value, alpha: valueAlpha, in: context, pixel: pixel)
    case .graph(let levels, _):
      drawChart(levels, in: value, alpha: valueAlpha, pixel: pixel)
    case .bars(let levels, _):
      drawBars(levels, in: value, alpha: valueAlpha, pixel: pixel)
    }
  }

  /// The status bar draws in a vibrant appearance without vibrancy blending, so secondary label colors come out as
  /// opaque grays. Fade `labelColor` instead, and only while drawing, because the faded copy freezes the appearance.
  private func ink(_ alpha: CGFloat) -> NSColor {
    alpha < 1 ? NSColor.labelColor.withAlphaComponent(alpha) : .labelColor
  }

  private func aligned(_ value: CGFloat, to pixel: CGFloat) -> CGFloat {
    (value / pixel).rounded() * pixel
  }

  /// Centers the lines' capitals vertically as one block, top line first.
  private func drawLines(
    _ lines: [TextLine],
    font: NSFont,
    alignedRightIn box: NSRect,
    alpha: CGFloat,
    in context: CGContext,
    pixel: CGFloat
  ) {
    let height = CGFloat(lines.count - 1) * style.stackedLineHeight + font.capHeight

    var baseline = box.minY + (box.height + height) / 2 - font.capHeight

    context.setFillColor(ink(alpha).cgColor)

    for line in lines {
      line.draw(at: CGPoint(x: aligned(box.maxX - line.width, to: pixel), y: aligned(baseline, to: pixel)), in: context)

      baseline -= style.stackedLineHeight
    }
  }

  /// Centers the line's ink, not its text, because a lone dash sits below the middle of the digits it stands for,
  /// and the gauges draw their dash in the middle.
  private func drawCentered(_ line: TextLine, in box: NSRect, alpha: CGFloat, in context: CGContext, pixel: CGFloat) {
    let glyphs = line.inkBounds

    context.setFillColor(ink(alpha).cgColor)

    line.draw(
      at: CGPoint(x: aligned(box.midX - glyphs.midX, to: pixel), y: aligned(box.midY - glyphs.midY, to: pixel)),
      in: context)
  }

  private func drawLabel(in context: CGContext, pixel: CGFloat) {
    guard !labelLetters.isEmpty else { return }

    let font = style.labelFont
    let columnWidth = labelLetters.map(\.width).max() ?? 0
    let height = CGFloat(labelLetters.count - 1) * style.labelLineHeight + font.capHeight

    var baseline = (bounds.height + height) / 2 - font.capHeight

    context.setFillColor(ink(style.valueAlpha).cgColor)

    for letter in labelLetters {
      let x = (columnWidth - letter.width) / 2

      letter.draw(at: CGPoint(x: aligned(x, to: pixel), y: aligned(baseline, to: pixel)), in: context)

      baseline -= style.labelLineHeight
    }
  }

  private func drawChart(_ levels: [Double?], in box: NSRect, alpha: CGFloat, pixel: CGFloat) {
    let plot = drawOutline(width: style.chartWidth, in: box)

    ink(alpha).setFill()
    AreaChart.path(levels, smoothing: style.chartSmoothing, in: plot, pixel: pixel).fill()
  }

  /// Fills each bar from the bottom, and a level of zero still fills one pixel, as the gauge does.
  private func drawBars(_ levels: [Double], in box: NSRect, alpha: CGFloat, pixel: CGFloat) {
    let plot = drawOutline(width: style.coresWidth(count: levels.count), in: box)

    ink(alpha).setFill()

    for (index, level) in levels.enumerated() {
      let height = plot.height * min(max(level, 0), 100) / 100

      NSRect(
        x: plot.minX + CGFloat(index) * (style.coreBarWidth + style.coreBarSpacing),
        y: plot.minY,
        width: style.coreBarWidth,
        height: max(pixel, aligned(height, to: pixel))
      ).fill(using: .sourceOver)
    }
  }

  /// Returns the area inside the outline that a chart's values may fill.
  private func drawOutline(width: CGFloat, in box: NSRect) -> NSRect {
    let frame = NSRect(x: box.minX, y: box.minY, width: width, height: style.height)
    let inset = style.outlineWidth / 2

    let outline = NSBezierPath(
      roundedRect: frame.insetBy(dx: inset, dy: inset),
      xRadius: style.cornerRadius,
      yRadius: style.cornerRadius
    )

    outline.lineWidth = style.outlineWidth

    ink(style.outlineAlpha).setStroke()

    outline.stroke()

    return frame.insetBy(dx: style.outlineWidth + style.chartPadding, dy: style.outlineWidth + style.chartPadding)
  }

  private func drawGauge(_ level: WidgetContent.Level, in box: NSRect, alpha: CGFloat, pixel: CGFloat) {
    let track = NSRect(x: box.minX, y: box.minY, width: style.gaugeWidth, height: style.height)
    let shape = NSBezierPath(roundedRect: track, xRadius: style.cornerRadius, yRadius: style.cornerRadius)

    ink(style.trackAlpha).setFill()
    shape.fill()

    let percent: Int

    switch level {
    case .measuring:
      return
    case .unavailable:
      let dash = NSRect(x: track.midX - 1.75, y: aligned(track.midY - 0.75, to: pixel), width: 3.5, height: 1.5)

      ink(alpha).setFill()
      NSBezierPath(roundedRect: dash, xRadius: 0.75, yRadius: 0.75).fill()

      return
    case .percent(let value):
      percent = value
    }

    NSGraphicsContext.saveGraphicsState()

    shape.addClip()

    ink(alpha).setFill()

    NSRect(
      x: track.minX,
      y: track.minY,
      width: track.width,
      height: max(pixel, aligned(track.height * CGFloat(percent) / 100, to: pixel))
    ).fill(using: .sourceOver)

    NSGraphicsContext.restoreGraphicsState()
  }
}
