import AppKit
import KernCore
import os

private let logger = Logger(subsystem: "Kern", category: "menu bar")

final class WidgetView: NSView {
  let widget: Widget
  let widestWidth: CGFloat
  private(set) var contentWidth: CGFloat
  var onContentWidthChange: () -> Void = {}

  /// Asks the owner to show the metric's readings again at the moment the value shown would go stale. The store
  /// counts staleness with the interval in force then, which the readings shown earlier cannot know.
  var onStaleDeadline: () -> Void = {}

  private let style: MenuBarStyle
  private let labelLetters: [TextLine]
  private let valueOffset: CGFloat
  private(set) var content: WidgetContent?
  private var valueText: TextLine?
  private lazy var staleCheck = StaleCheck { [weak self] in self?.onStaleDeadline() }
  private(set) var drawCount = 0

  init(widget: Widget, label: String?, style: MenuBarStyle) {
    self.widget = widget
    self.style = style
    self.labelLetters = label.map { $0.map { TextLine(String($0), font: style.labelFont) } } ?? []
    self.valueOffset = style.valueOffset(label: label)
    self.widestWidth = style.width(of: widget, label: label)
    self.contentWidth = widestWidth

    super.init(frame: NSRect(x: 0, y: 0, width: widestWidth, height: style.height))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("WidgetView is not loaded from a nib")
  }

  func show(_ readings: MetricReadings) {
    let content = widget.content(for: readings, at: .now)

    render(content)

    staleCheck.schedule(at: content.isStale ? nil : readings.staleAt)
  }

  private func render(_ content: WidgetContent) {
    guard content != self.content else { return }

    if case .reading(let text, _) = content {
      let valueText = TextLine(text, font: style.valueFont)
      let contentWidth = valueOffset + ceil(valueText.width)

      self.valueText = valueText

      if contentWidth != self.contentWidth {
        self.contentWidth = contentWidth
        onContentWidthChange()
      }
    }

    self.content = content
    needsDisplay = true

    logger.debug("redraw \(self.widget.rawValue, privacy: .public): \(content, privacy: .public)")
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
      if let valueText {
        drawText(valueText, alignedRightIn: value, alpha: valueAlpha, in: context, pixel: pixel)
      }

    case .level(let level, _):
      drawGauge(level, in: value, alpha: valueAlpha, pixel: pixel)

    case .graph(let levels, _):
      drawChart(levels, in: value, alpha: valueAlpha, pixel: pixel)
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

  private func drawText(
    _ text: TextLine,
    alignedRightIn box: NSRect,
    alpha: CGFloat,
    in context: CGContext,
    pixel: CGFloat
  ) {
    let baseline = box.minY + (box.height - style.valueFont.capHeight) / 2
    let origin = CGPoint(x: aligned(box.maxX - text.width, to: pixel), y: aligned(baseline, to: pixel))

    context.setFillColor(ink(alpha).cgColor)
    text.draw(at: origin, in: context)
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
    let frame = NSRect(x: box.minX, y: box.minY, width: style.chartWidth, height: style.height)
    let inset = style.outlineWidth / 2
    let outline = NSBezierPath(
      roundedRect: frame.insetBy(dx: inset, dy: inset),
      xRadius: style.cornerRadius,
      yRadius: style.cornerRadius
    )

    outline.lineWidth = style.outlineWidth

    ink(style.outlineAlpha).setStroke()

    outline.stroke()

    let plot = frame.insetBy(dx: style.outlineWidth + style.chartPadding, dy: style.outlineWidth + style.chartPadding)

    ink(alpha).setFill()
    AreaChart.path(levels, smoothing: style.chartSmoothing, in: plot, pixel: pixel).fill()
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
