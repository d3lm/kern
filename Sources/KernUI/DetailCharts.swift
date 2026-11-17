import AppKit
import KernCore

/// A thin flat-coloured bar on its track, filled over a part of its length.
final class LevelBar: NSView {
  private let style: DetailStyle
  private(set) var fill: ClosedRange<Double>?
  private(set) var color: NSColor = .clear
  private var isStale = false

  init(style: DetailStyle) {
    self.style = style

    super.init(frame: .zero)

    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("LevelBar is not loaded from a nib")
  }

  func show(_ fill: ClosedRange<Double>?, color: NSColor, isStale: Bool) {
    guard fill != self.fill || color != self.color || isStale != self.isStale else { return }

    self.fill = fill
    self.color = color
    self.isStale = isStale
    needsDisplay = true
  }

  /// A range that starts at 0 is a level and is at least a pixel long. Any other range is at least `minimum` long,
  /// so a single temperature still shows where it is.
  nonisolated static func span(of fill: ClosedRange<Double>, in width: CGFloat, minimum: CGFloat, pixel: CGFloat)
    -> ClosedRange<CGFloat>
  {
    let start = width * fill.lowerBound
    let end = width * fill.upperBound

    guard fill.lowerBound > 0 else { return 0...max(pixel, end) }
    guard end - start < minimum else { return start...end }

    let middle = min(max((start + end) / 2, minimum / 2), width - minimum / 2)

    return (middle - minimum / 2)...(middle + minimum / 2)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }

    let radius = style.barCornerRadius
    let pixel = 1 / (window?.backingScaleFactor ?? 2)

    style.track.setFill()

    NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

    guard let fill else { return }

    let span = Self.span(of: fill, in: bounds.width, minimum: style.rangeMinimumWidth, pixel: pixel)
    let rect = NSRect(x: span.lowerBound, y: 0, width: span.upperBound - span.lowerBound, height: bounds.height)

    context.saveGState()
    context.setAlpha(isStale ? style.staleAlpha : 1)
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    context.restoreGState()
  }
}

/// One bar per sample. The gradient spans the whole chart, so a bar shows only the part of it at its own height.
final class HistoryChartView: NSView {
  enum Fill {
    case gradient(DetailStyle.Gradient)
    case temperature
  }

  private let title: String
  private let fill: Fill
  private let style: DetailStyle
  private(set) var content: HistoryChart?
  private(set) var drawCount = 0

  init(title: String, fill: Fill, style: DetailStyle) {
    self.title = title
    self.fill = fill
    self.style = style

    let height = if case .temperature = fill { style.temperatureHistoryHeight } else { style.historyHeight }

    super.init(frame: NSRect(x: 0, y: 0, width: style.contentWidth, height: height))

    setAccessibilityElement(true)
    setAccessibilityRole(.image)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("HistoryChartView is not loaded from a nib")
  }

  func show(_ content: HistoryChart?) {
    guard content != self.content else { return }

    self.content = content
    needsDisplay = true

    setAccessibilityLabel("\(title) history. \(content?.spokenSummary ?? "")")
  }

  /// The middle of each 1-point line, which stays inside the chart, so the line at 100 is not cut in half.
  nonisolated static func guideYs(_ levels: [Double], in box: CGRect) -> [CGFloat] {
    levels.map { level in
      min((box.minY + box.height * level / 100).rounded(), box.maxY - 0.5)
    }
  }

  /// Levels are out of 100, which for a temperature is 100 °C. A sample without a value has no bar.
  nonisolated static func bars(_ levels: [Double?], in box: CGRect, share: CGFloat, minimumHeight: CGFloat)
    -> [(level: Double, rect: CGRect)]
  {
    let slotWidth = box.width / CGFloat(levels.count)
    let width = slotWidth * share

    return levels.enumerated().compactMap { slot, level in
      level.map { level in
        let rect = CGRect(
          x: box.minX + CGFloat(slot) * slotWidth + (slotWidth - width) / 2,
          y: box.minY,
          width: width,
          height: max(minimumHeight, box.height * min(max(level, 0), 100) / 100)
        )

        return (level, rect)
      }
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    drawCount += 1

    guard let context = NSGraphicsContext.current?.cgContext else { return }

    context.saveGState()
    context.setStrokeColor(style.guide.cgColor)
    context.setLineWidth(1)
    context.setLineDash(phase: 0, lengths: style.guideDash)

    for y in Self.guideYs(style.guideLevels, in: bounds) {
      context.strokeLineSegments(between: [CGPoint(x: bounds.minX, y: y), CGPoint(x: bounds.maxX, y: y)])
    }

    context.restoreGState()

    guard let content else { return }

    let bars = Self.bars(
      content.levels, in: bounds, share: style.historyBarShare, minimumHeight: style.minimumBarHeight)

    guard !bars.isEmpty else { return }

    context.saveGState()
    context.setAlpha(content.isStale ? style.staleAlpha : 1)

    switch fill {
    case .gradient(let gradient):
      context.addRects(bars.map(\.rect))
      context.clip()
      context.drawLinearGradient(
        gradient.cgGradient,
        start: CGPoint(x: bounds.minX, y: bounds.maxY),
        end: CGPoint(x: bounds.minX, y: bounds.minY),
        options: []
      )

    case .temperature:
      for hot in [false, true] {
        context.setFillColor((hot ? style.hot : style.coolBar).cgColor)
        context.fill(bars.filter { ($0.level > style.hotCelsius) == hot }.map(\.rect))
      }
    }

    context.restoreGState()
  }
}

/// The CPU's cores on one line, the performance cores on the left and the efficiency cores on the right, or each kind
/// on lines of its own when they do not fit on one.
final class CoreChartView: NSView {
  private let title: String
  private let style: DetailStyle
  let groups: [CoreGroupView]
  private(set) var content: CoreChart?
  private lazy var missing = TextLine("No per-core values", font: style.captionFont)

  init(title: String, kinds: [CoreKind]?, style: DetailStyle) {
    let counts = [CoreKind.performance, .efficiency].map { kind in (kind, kinds?.count { $0 == kind } ?? 0) }
    let natural = counts.filter { $0.1 > 0 }.map { CoreGroupView.naturalWidth(count: $0.1, style: style) }
    let fitsOnOneLine =
      natural.reduce(0, +) + CGFloat(max(natural.count - 1, 0)) * style.coreGroupGap
      <= style.contentWidth

    self.title = title
    self.style = style

    self.groups = counts.filter { $0.1 > 0 }.map { kind, count in
      CoreGroupView(kind: kind, count: count, width: fitsOnOneLine ? nil : style.contentWidth, style: style)
    }

    super.init(frame: .zero)

    var top: CGFloat = 0

    for group in groups {
      if fitsOnOneLine {
        let isLast = group === groups.last && groups.count > 1

        group.setFrameOrigin(NSPoint(x: isLast ? style.contentWidth - group.frame.width : 0, y: 0))
        top = max(top, group.frame.height)
      } else {
        group.setFrameOrigin(NSPoint(x: 0, y: top == 0 ? 0 : top + style.coreLineSpacing))
        top = group.frame.maxY
      }

      addSubview(group)
    }

    setFrameSize(NSSize(width: style.contentWidth, height: groups.isEmpty ? style.coreTrack.height : top))
    setAccessibilityElement(true)
    setAccessibilityRole(.image)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("CoreChartView is not loaded from a nib")
  }

  override var isFlipped: Bool { true }

  func show(_ content: CoreChart) {
    guard content != self.content else { return }

    for group in groups {
      let shares = content.cores.map { group.kind == .performance ? $0.performance : $0.efficiency }

      group.show(shares: shares, isStale: content.isStale)
    }

    self.content = content

    setAccessibilityLabel("\(title) per core. \(content.spokenSummary)")
  }

  override func draw(_ dirtyRect: NSRect) {
    guard groups.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }

    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.setFillColor(NSColor.secondaryLabelColor.cgColor)
    missing.draw(at: CGPoint(x: 0, y: (bounds.height + style.captionFont.capHeight) / 2), in: context)
  }
}

/// Shows one kind of core with its letter, a track for each core filled from the bottom, and the mean of the kind.
final class CoreGroupView: NSView {
  let kind: CoreKind
  let count: Int
  private(set) var shares: [Double]?
  private var isStale = false
  private let style: DetailStyle
  private let label: TextLine
  private let perLine: Int

  init(kind: CoreKind, count: Int, width: CGFloat?, style: DetailStyle) {
    self.kind = kind
    self.count = count
    self.style = style
    self.label = TextLine(kind == .performance ? "P" : "E", font: style.labelFont)

    let fitting = width.map { width in
      Int((width - Self.chromeWidth(style: style) + style.coreSpacing) / (style.coreTrack.width + style.coreSpacing))
    }

    let perLine = max(1, min(count, fitting ?? count))
    let lines = (count + perLine - 1) / perLine

    self.perLine = perLine

    super.init(
      frame: NSRect(
        x: 0, y: 0,
        width: width ?? Self.naturalWidth(count: count, style: style),
        height: CGFloat(lines) * style.coreTrack.height + CGFloat(lines - 1) * style.coreLineSpacing
      ))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("CoreGroupView is not loaded from a nib")
  }

  static func naturalWidth(count: Int, style: DetailStyle) -> CGFloat {
    chromeWidth(style: style) + CGFloat(count) * (style.coreTrack.width + style.coreSpacing) - style.coreSpacing
  }

  private static func chromeWidth(style: DetailStyle) -> CGFloat {
    let letter = max(TextLine("P", font: style.labelFont).width, TextLine("E", font: style.labelFont).width)
    let mean = TextLine("100%", font: style.valueFont).width

    return ceil(letter) + 2 * style.coreLabelSpacing + ceil(mean)
  }

  func show(shares: [Double]?, isStale: Bool) {
    guard shares != self.shares || isStale != self.isStale else { return }

    self.shares = shares
    self.isStale = isStale
    needsDisplay = true
  }

  /// Returns the frame of each track in view coordinates, which start at the bottom. The first line of tracks is the
  /// top one.
  func trackFrames() -> [CGRect] {
    let barsStart = ceil(label.width) + style.coreLabelSpacing

    return (0..<count).map { index in
      let line = index / perLine
      let column = index % perLine

      return CGRect(
        x: barsStart + CGFloat(column) * (style.coreTrack.width + style.coreSpacing),
        y: bounds.height - CGFloat(line + 1) * style.coreTrack.height - CGFloat(line) * style.coreLineSpacing,
        width: style.coreTrack.width,
        height: style.coreTrack.height
      )
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }

    let tracks = trackFrames()
    let firstLine = bounds.height - style.coreTrack.height
    let textY = firstLine + (style.coreTrack.height - style.labelFont.capHeight) / 2
    let meanX = (tracks.map(\.maxX).max() ?? 0) + style.coreLabelSpacing
    let mean = shares.flatMap(CoreChart.mean).map { "\($0)%" } ?? WidgetContent.unavailableText
    let gradient = style.cpuGradient.cgGradient

    context.textMatrix = .identity
    context.setFillColor(NSColor.secondaryLabelColor.cgColor)
    label.draw(at: CGPoint(x: 0, y: textY), in: context)

    context.setAlpha(isStale ? style.staleAlpha : 1)
    context.setFillColor(NSColor.labelColor.cgColor)
    TextLine(mean, font: style.valueFont).draw(at: CGPoint(x: meanX, y: textY), in: context)

    for (index, track) in tracks.enumerated() {
      let shape = CGPath(
        roundedRect: track, cornerWidth: style.coreCornerRadius, cornerHeight: style.coreCornerRadius, transform: nil)

      context.addPath(shape)
      context.setFillColor(style.track.cgColor)
      context.fillPath()

      guard let share = shares.flatMap({ index < $0.count ? $0[index] : nil }), share > 0 else { continue }

      context.saveGState()
      context.addPath(shape)
      context.clip()
      context.clip(
        to: CGRect(x: track.minX, y: track.minY, width: track.width, height: track.height * min(share, 100) / 100))
      context.drawLinearGradient(
        gradient,
        start: CGPoint(x: track.minX, y: track.maxY),
        end: CGPoint(x: track.minX, y: track.minY),
        options: []
      )
      context.restoreGState()
    }
  }
}

extension DetailStyle.Gradient {
  /// Resolved for the appearance being drawn, so it must be made while drawing.
  var cgGradient: CGGradient {
    CGGradient(
      colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
      colors: [top.cgColor, bottom.cgColor] as CFArray,
      locations: [0, 1]
    )!
  }
}
