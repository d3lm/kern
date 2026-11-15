import AppKit
import KernCore
import os

private let logger = Logger(subsystem: "Kern", category: "menu bar")

/// Draws one widget. It asks to be redrawn only when its content changes, which happens when a sample of its
/// metric arrives and once more when the last value goes stale. Nothing redraws between those moments.
///
/// The menu bar also draws the item again for every other display after each change, in that display's appearance,
/// so drawing must stay cheap: text is laid out once, when it changes, and drawing only places the laid-out lines
/// and fills the chart.
final class WidgetView: NSView {
  /// Text laid out once and drawn in whatever color is current, so one layout serves every appearance.
  private struct Line {
    let line: CTLine
    let width: CGFloat

    init(_ text: String, font: NSFont) {
      let string = NSAttributedString(
        string: text,
        attributes: [.font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
      )

      line = CTLineCreateWithAttributedString(string)
      width = CTLineGetTypographicBounds(line, nil, nil, nil)
    }
  }

  let widget: Widget
  let widestWidth: CGFloat
  private(set) var contentWidth: CGFloat
  var onContentWidthChange: () -> Void = {}
  private let style: MenuBarStyle
  private let labelLetters: [Line]
  private let valueOffset: CGFloat
  private(set) var content: WidgetContent?
  private var valueText: Line?
  private(set) var drawCount = 0

  private var staleCheck: (deadline: ContinuousClock.Instant, task: Task<Void, Never>)?

  init(widget: Widget, label: String?, style: MenuBarStyle) {
    self.widget = widget
    self.style = style
    self.labelLetters = label.map { $0.map { Line(String($0), font: style.labelFont) } } ?? []
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
    render(widget.content(for: readings, at: .now))
    checkForStaleness(at: readings.staleAt)
  }

  private func render(_ content: WidgetContent) {
    guard content != self.content else { return }

    if case .reading(let text, _) = content {
      let valueText = Line(text, font: style.valueFont)
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

  /// Schedules one redraw for the moment the value goes stale. Every successful sample moves that moment,
  /// so while samples keep arriving the check never fires.
  private func checkForStaleness(at staleAt: ContinuousClock.Instant?) {
    guard staleAt != staleCheck?.deadline else { return }

    staleCheck?.task.cancel()
    staleCheck = nil

    guard let staleAt, content?.isStale == false else { return }

    let task = Task { [weak self] in
      do {
        try await Task.sleep(until: staleAt, tolerance: .milliseconds(500), clock: .continuous)
      } catch {
        return
      }

      self?.markStale(dueAt: staleAt)
    }

    staleCheck = (staleAt, task)
  }

  /// A newer sample can move the deadline after this check has woken up, when cancelling it no longer stops it,
  /// so only the check for the current deadline may mark the value stale.
  private func markStale(dueAt deadline: ContinuousClock.Instant) {
    guard staleCheck?.deadline == deadline else { return }

    staleCheck = nil

    if let content {
      render(content.markedStale)
    }
  }

  // MARK: Drawing

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

    case .level(let percent, _):
      drawGauge(percent, in: value, alpha: valueAlpha, pixel: pixel)

    case .graph(let levels, _):
      drawChart(levels, in: value, alpha: valueAlpha, pixel: pixel)
    }
  }

  /// The status bar draws its items in a vibrant appearance but does not blend them with vibrancy, and in vibrant
  /// appearances the secondary label colors are opaque grays meant for that blending. Fading the label color instead
  /// dims correctly in every appearance. It must be faded while drawing, because the faded copy keeps only the
  /// appearance current when it is made.
  private func ink(_ alpha: CGFloat) -> NSColor {
    alpha < 1 ? NSColor.labelColor.withAlphaComponent(alpha) : .labelColor
  }

  private func aligned(_ value: CGFloat, to pixel: CGFloat) -> CGFloat {
    (value / pixel).rounded() * pixel
  }

  private func draw(_ line: Line, at point: CGPoint, in context: CGContext) {
    context.textPosition = point
    CTLineDraw(line.line, context)
  }

  /// Right-aligned, so that the room kept for a third digit stays at the outer edge rather than opening a gap before
  /// the next widget. The capital letters and digits are centered vertically, which is where the eye judges text to
  /// be centered.
  private func drawText(
    _ text: Line,
    alignedRightIn box: NSRect,
    alpha: CGFloat,
    in context: CGContext,
    pixel: CGFloat
  ) {
    let baseline = box.minY + (box.height - style.valueFont.capHeight) / 2
    let origin = CGPoint(x: aligned(box.maxX - text.width, to: pixel), y: aligned(baseline, to: pixel))

    context.setFillColor(ink(alpha).cgColor)
    draw(text, at: origin, in: context)
  }

  /// One letter per line, each centered in the column, with the column centered vertically.
  private func drawLabel(in context: CGContext, pixel: CGFloat) {
    guard !labelLetters.isEmpty else { return }

    let font = style.labelFont
    let columnWidth = labelLetters.map(\.width).max() ?? 0
    let height = CGFloat(labelLetters.count - 1) * style.labelLineHeight + font.capHeight
    var baseline = (bounds.height + height) / 2 - font.capHeight

    context.setFillColor(ink(style.valueAlpha).cgColor)

    for letter in labelLetters {
      let x = (columnWidth - letter.width) / 2

      draw(letter, at: CGPoint(x: aligned(x, to: pixel), y: aligned(baseline, to: pixel)), in: context)
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
    let path = NSBezierPath()

    for area in Self.areas(Self.smoothed(levels, radius: style.chartSmoothing), in: plot, pixel: pixel) {
      path.move(to: area[0])

      for point in area.dropFirst() {
        path.line(to: point)
      }

      path.close()
    }

    ink(alpha).setFill()
    path.fill()
  }

  /// Each level replaced by the mean of the levels up to `radius` slots away on either side, within its run of slots
  /// that have a level. A gap stays a gap and is never averaged across, and a slot keeps a level exactly when it had one.
  nonisolated static func smoothed(_ levels: [Double?], radius: Int) -> [Double?] {
    levels.indices.map { slot in
      guard levels[slot] != nil else { return nil }

      var neighbors: [Double] = []
      var before = slot

      while before > slot - radius, before > levels.startIndex, let level = levels[before - 1] {
        neighbors.append(level)
        before -= 1
      }

      var after = slot

      while after < slot + radius, after < levels.endIndex - 1, let level = levels[after + 1] {
        neighbors.append(level)
        after += 1
      }

      let all = neighbors + [levels[slot]!]

      return all.reduce(0, +) / Double(all.count)
    }
  }

  /// The filled area under the chart's line, as one polygon for each run of slots that have a level, so that a slot
  /// without a level is a gap in the area. The line runs through the middle of each slot and is flat across the outer
  /// half of a run's first and last slot, so that a single level between two gaps still fills its slot. A level of
  /// zero still rises one pixel, so that a reading of zero never looks like a gap.
  nonisolated static func areas(_ levels: [Double?], in plot: CGRect, pixel: CGFloat) -> [[CGPoint]] {
    let slotWidth = plot.width / CGFloat(levels.count)
    var areas: [[CGPoint]] = []
    var run: [(slot: Int, top: CGFloat)] = []

    func closeRun() {
      guard let first = run.first, let last = run.last else { return }

      let start = plot.minX + CGFloat(first.slot) * slotWidth
      let end = plot.minX + CGFloat(last.slot + 1) * slotWidth
      let line = run.map { CGPoint(x: plot.minX + (CGFloat($0.slot) + 0.5) * slotWidth, y: $0.top) }

      areas.append(
        [CGPoint(x: start, y: plot.minY), CGPoint(x: start, y: first.top)] + line
          + [CGPoint(x: end, y: last.top), CGPoint(x: end, y: plot.minY)])
      run = []
    }

    for (slot, level) in levels.enumerated() {
      guard let level else {
        closeRun()
        continue
      }

      run.append((slot, plot.minY + max(pixel, plot.height * level / 100)))
    }

    closeRun()

    return areas
  }

  /// Fills from the bottom up to the level. Without a level the gauge shows a dash, never an empty gauge, which would
  /// read as zero; a level of zero still fills one pixel for the same reason.
  private func drawGauge(_ percent: Int?, in box: NSRect, alpha: CGFloat, pixel: CGFloat) {
    let track = NSRect(x: box.minX, y: box.minY, width: style.gaugeWidth, height: style.height)
    let shape = NSBezierPath(roundedRect: track, xRadius: style.cornerRadius, yRadius: style.cornerRadius)

    ink(style.trackAlpha).setFill()
    shape.fill()

    guard let percent else {
      let dash = NSRect(x: track.midX - 1.75, y: aligned(track.midY - 0.75, to: pixel), width: 3.5, height: 1.5)

      ink(alpha).setFill()
      NSBezierPath(roundedRect: dash, xRadius: 0.75, yRadius: 0.75).fill()

      return
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
