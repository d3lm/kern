import AppKit
import KernCore

/// AppKit draws a view larger than about 36,000 square points (190 by 190) with Metal, which permanently costs
/// several MiB, so large shapes must be layer properties. Views are placed by frame, not Auto Layout, because
/// malloc keeps part of what Auto Layout allocates on each opening.
final class DetailView: NSView {
  let sections: [DetailSection]
  let cards: [DetailCard]
  var fittingSizeChanged: () -> Void = {}
  private let style: DetailStyle
  private var size = NSSize.zero

  init(sources: [Metric: MetricSource], style: DetailStyle = DetailStyle()) {
    sections = Metric.allCases.compactMap { metric in
      sources[metric].map { DetailSection(metric: metric, source: $0, style: style) }
    }

    var cards: [DetailCard] = []

    for section in sections {
      let heading = section.metric.detailHeading
      let views: [NSView] = [section.history].compactMap { $0 } + section.rows

      if let card = cards.last, card.heading == heading {
        card.add(views)
      } else {
        cards.append(DetailCard(heading: heading, symbol: Self.symbol(for: section.metric), views: views, style: style))
      }

      if let cores = section.cores {
        cards.append(DetailCard(heading: "CPU Cores", symbol: Self.symbol(for: .cpu), views: [cores], style: style))
      }
    }

    self.cards = cards
    self.style = style

    super.init(frame: .zero)

    for card in cards {
      addSubview(card)
    }

    for section in sections {
      section.changed = { [weak self] in self?.arrange() }
    }

    arrange()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("DetailView is not loaded from a nib")
  }

  override var isFlipped: Bool { true }

  override var fittingSize: NSSize { size }

  func show(_ readings: MetricReadings, for metric: Metric) {
    for section in sections where section.metric == metric {
      section.show(readings)
    }
  }

  private func arrange() {
    var top = style.panelPadding

    for card in cards {
      card.arrange()
      card.setFrameOrigin(NSPoint(x: style.panelPadding, y: top))
      top = card.frame.maxY + style.cardSpacing
    }

    let size = NSSize(
      width: style.cardWidth + 2 * style.panelPadding,
      height: top - style.cardSpacing + style.panelPadding
    )

    if size != self.size {
      self.size = size
      fittingSizeChanged()
    }
  }

  private static func symbol(for metric: Metric) -> String {
    switch metric {
    case .cpu: "cpu"
    case .gpu: "display"
    case .temperature: "thermometer.medium"
    case .memory, .memoryPressure: "memorychip"
    }
  }
}

@MainActor
final class DetailSection {
  let metric: Metric
  let rows: [DetailRowView]
  let history: HistoryChartView?
  let cores: CoreChartView?
  var changed: () -> Void = {}
  private let source: MetricSource
  private lazy var staleCheck = StaleCheck { [weak self] in self?.markStale() }

  init(metric: Metric, source: MetricSource, style: DetailStyle) {
    let title = metric.detailTitle(measuring: source.quantity)

    self.metric = metric
    self.source = source
    self.rows = metric.detailLines.map { _ in DetailRowView(style: style) }
    self.history = metric == .cpu || metric == .gpu ? HistoryChartView(title: title, style: style) : nil
    self.cores = metric == .cpu ? CoreChartView(title: title, kinds: source.coreKinds, style: style) : nil
  }

  func show(_ readings: MetricReadings) {
    let now = ContinuousClock.now
    let contents = metric.detailLines.map { metric.detailRow($0, for: readings, source: source, at: now) }

    for (row, content) in zip(rows, contents) {
      row.show(content, at: now)
    }

    history?.show(metric.historyChart(for: readings, at: now))
    cores?.show(metric.coreChart(for: readings, at: now))
    staleCheck.schedule(at: contents[0].isStale ? nil : readings.staleAt)
    changed()
  }

  private func markStale() {
    for row in rows {
      if let content = row.content {
        row.show(content.markedStale, at: .now)
      }
    }

    if let chart = history?.content {
      history?.show(chart.markedStale)
    }

    if let chart = cores?.content {
      cores?.show(chart.markedStale)
    }

    changed()
  }
}

final class DetailCard: NSView {
  let heading: String
  private let style: DetailStyle
  private let icon: NSImageView
  private let title: NSTextField
  private var lines: [NSView] = []

  init(heading: String, symbol: String, views: [NSView], style: DetailStyle) {
    self.heading = heading
    self.style = style

    icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
    title = NSTextField(labelWithString: heading.uppercased())

    super.init(frame: .zero)

    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: style.headingFont.pointSize, weight: .medium)
    icon.contentTintColor = .secondaryLabelColor
    icon.setAccessibilityElement(false)
    icon.sizeToFit()
    title.font = style.headingFont
    title.textColor = .secondaryLabelColor
    title.setAccessibilityLabel(heading)
    title.sizeToFit()

    wantsLayer = true
    addSubview(icon)
    addSubview(title)
    add(views)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("DetailCard is not loaded from a nib")
  }

  override var isFlipped: Bool { true }

  func add(_ views: [NSView]) {
    lines += views
    views.forEach(addSubview)
  }

  func arrange() {
    let padding = style.cardPadding
    let headingHeight = title.alignmentSize.height
    var top = padding + headingHeight

    icon.setAlignmentOrigin(NSPoint(x: padding, y: padding + (headingHeight - icon.alignmentSize.height) / 2))
    title.setAlignmentOrigin(NSPoint(x: padding + icon.alignmentSize.width + style.headingSpacing, y: padding))

    for line in lines {
      line.setFrameOrigin(NSPoint(x: padding, y: top + style.lineSpacing))
      top = line.frame.maxY
    }

    setFrameSize(NSSize(width: style.cardWidth, height: top + padding))
  }

  /// A card is too large to draw without AppKit switching to Metal, so its fill and outline are layer properties.
  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    guard let layer else { return }

    layer.cornerRadius = style.cardCornerRadius
    layer.borderWidth = 1
    layer.backgroundColor = NSColor.labelColor.withAlphaComponent(style.cardFillAlpha).cgColor
    layer.borderColor = NSColor.labelColor.withAlphaComponent(style.cardOutlineAlpha).cgColor
  }
}

final class DetailRowView: NSView {
  private static let timeStyle = Date.FormatStyle(date: .omitted, time: .standard)

  private let style: DetailStyle
  private let label: NSTextField
  private let value: NSTextField
  private let bar: LevelBar
  private let status: NSTextField
  private(set) var content: DetailRow?

  init(style: DetailStyle) {
    self.style = style
    label = NSTextField(labelWithString: "")
    value = NSTextField(labelWithString: "")
    bar = LevelBar(style: style)
    status = NSTextField(wrappingLabelWithString: "")

    super.init(frame: .zero)

    label.font = style.labelFont
    value.font = style.valueFont
    value.alignment = .right
    status.font = style.captionFont
    status.textColor = .secondaryLabelColor
    status.isSelectable = false

    for view in [label, value, status] {
      view.setAccessibilityElement(false)
      addSubview(view)
    }

    addSubview(bar)
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    arrange()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("DetailRowView is not loaded from a nib")
  }

  override var isFlipped: Bool { true }

  var labelText: String { label.stringValue }
  var valueText: String { value.stringValue }
  var statusText: String { status.isHidden ? "" : status.stringValue }

  func show(_ content: DetailRow, at now: ContinuousClock.Instant) {
    guard content != self.content else { return }

    self.content = content

    let statusText = content.statusText(at: now, date: .now, timeStyle: Self.timeStyle)

    label.stringValue = content.label
    value.stringValue = content.valueText
    value.textColor = content.isStale ? .tertiaryLabelColor : .labelColor
    bar.show(content.value, isStale: content.isStale)
    status.stringValue = statusText ?? ""
    status.isHidden = statusText == nil
    toolTip = content.explanation

    setAccessibilityValue(
      ["\(content.title), \(content.spokenValue)", statusText].compactMap { $0 }.joined(separator: ". "))

    setAccessibilityHelp(content.explanation)
    arrange()
  }

  private func arrange() {
    label.sizeToFit()
    value.sizeToFit()
    label.setAlignmentOrigin(.zero)

    value.setAlignmentOrigin(
      NSPoint(
        x: style.valueEnd - value.alignmentSize.width,
        y: label.firstBaselineOffsetFromTop - value.firstBaselineOffsetFromTop))

    let lineHeight = label.alignmentSize.height
    var top = lineHeight

    bar.frame = NSRect(
      x: style.contentWidth - style.barWidth,
      y: (lineHeight - style.barHeight) / 2,
      width: style.barWidth,
      height: style.barHeight
    )

    if !status.isHidden {
      let insets = status.alignmentRectInsets
      let width = style.contentWidth + insets.left + insets.right
      let height = status.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height

      status.setFrameSize(NSSize(width: width, height: height))
      status.setAlignmentOrigin(NSPoint(x: 0, y: top + style.captionSpacing))
      top += style.captionSpacing + status.alignmentSize.height
    }

    setFrameSize(NSSize(width: style.contentWidth, height: top))
  }
}

extension NSView {
  fileprivate var alignmentSize: NSSize {
    let insets = alignmentRectInsets

    return NSSize(width: frame.width - insets.left - insets.right, height: frame.height - insets.top - insets.bottom)
  }

  /// Assumes a flipped superview.
  fileprivate func setAlignmentOrigin(_ origin: NSPoint) {
    setFrameOrigin(NSPoint(x: origin.x - alignmentRectInsets.left, y: origin.y - alignmentRectInsets.top))
  }
}

final class LevelBar: NSView {
  private let style: DetailStyle
  private(set) var value: DetailRow.Value?
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

  func show(_ value: DetailRow.Value?, isStale: Bool) {
    guard value != self.value || isStale != self.isStale else { return }

    self.value = value
    self.isStale = isStale
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    let radius = bounds.height / 2
    let pixel = 1 / (window?.backingScaleFactor ?? 2)

    NSColor.labelColor.withAlphaComponent(style.trackAlpha).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

    guard let value else { return }

    let fill = NSRect(x: 0, y: 0, width: max(pixel, bounds.width * value.fraction), height: bounds.height)

    style.barColor(for: value).withAlphaComponent(isStale ? style.staleAlpha : 1).setFill()
    NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
  }
}

final class HistoryChartView: NSView {
  private let title: String
  private let style: DetailStyle
  private(set) var content: HistoryChart?
  private(set) var drawCount = 0

  init(title: String, style: DetailStyle) {
    self.title = title
    self.style = style

    super.init(frame: NSRect(x: 0, y: 0, width: style.contentWidth, height: style.historyHeight))

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

  nonisolated static func bars(_ levels: [Double?], in box: CGRect, spacing: CGFloat, pixel: CGFloat) -> [CGRect] {
    let slotWidth = box.width / CGFloat(levels.count)

    return levels.enumerated().compactMap { slot, level in
      level.map { level in
        CGRect(
          x: box.minX + CGFloat(slot) * slotWidth,
          y: box.minY,
          width: max(pixel, slotWidth - spacing),
          height: max(pixel, box.height * min(level, 100) / 100)
        )
      }
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    drawCount += 1

    guard let content, let context = NSGraphicsContext.current else { return }

    let pixel = 1 / (window?.backingScaleFactor ?? 2)
    let bars = Self.bars(content.levels, in: bounds, spacing: style.historyBarSpacing, pixel: pixel)
    let shape = NSBezierPath()

    // clipping to an empty path leaves the whole view drawable, and the gradient would fill it
    guard !bars.isEmpty else { return }

    for bar in bars {
      shape.append(NSBezierPath(rect: bar))
    }

    NSGraphicsContext.saveGraphicsState()
    context.cgContext.setAlpha(content.isStale ? style.staleAlpha : 1)
    shape.addClip()
    NSGradient(starting: style.historyGradient.bottom, ending: style.historyGradient.top)?.draw(in: bounds, angle: 90)
    NSGraphicsContext.restoreGraphicsState()
  }
}

/// Each core's line is its own view, because one view for all of them is too large to draw without Metal.
final class CoreChartView: NSView {
  private let title: String
  private let style: DetailStyle
  private(set) var content: CoreChart?
  private lazy var missing = TextLine("No per-core values", font: style.captionFont)
  private let groups: [(kind: CoreKind, rows: [CoreRowView])]

  init(title: String, kinds: [CoreKind]?, style: DetailStyle) {
    let names = [(kind: CoreKind.performance, name: "P-Core"), (kind: .efficiency, name: "E-Core")]
    let sizes = names.map { group in kinds?.count { $0 == group.kind } ?? 0 }
    let tops = Self.rowTops(sizes: sizes, rowHeight: style.coreRowHeight, groupSpacing: style.coreGroupSpacing)
    let height = Self.height(sizes: sizes, rowHeight: style.coreRowHeight, groupSpacing: style.coreGroupSpacing)

    self.title = title
    self.style = style

    self.groups = zip(zip(names, sizes).filter { $1 > 0 }.map(\.0), tops).map { group, tops in
      let rows = tops.enumerated().map { index, top in
        let row = CoreRowView(name: "\(group.name) #\(index + 1)", style: style)

        row.setFrameOrigin(NSPoint(x: 0, y: height - top - style.coreRowHeight))

        return row
      }

      return (group.kind, rows)
    }

    super.init(frame: NSRect(x: 0, y: 0, width: style.contentWidth, height: height))

    groups.flatMap(\.rows).forEach(addSubview)
    setAccessibilityElement(true)
    setAccessibilityRole(.image)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("CoreChartView is not loaded from a nib")
  }

  func show(_ content: CoreChart) {
    guard content != self.content else { return }

    for group in groups {
      let shares = content.cores.map { group.kind == .performance ? $0.performance : $0.efficiency } ?? []

      for (index, row) in group.rows.enumerated() {
        row.show(share: index < shares.count ? shares[index] : nil, isStale: content.isStale)
      }
    }

    self.content = content

    setAccessibilityLabel("\(title) per core. \(content.spokenSummary)")
  }

  nonisolated static func rowTops(sizes: [Int], rowHeight: CGFloat, groupSpacing: CGFloat) -> [[CGFloat]] {
    var top: CGFloat = 0

    return sizes.filter { $0 > 0 }.map { count in
      defer { top += groupSpacing }

      return (0..<count).map { _ in
        defer { top += rowHeight }

        return top
      }
    }
  }

  nonisolated static func height(sizes: [Int], rowHeight: CGFloat, groupSpacing: CGFloat) -> CGFloat {
    guard let last = rowTops(sizes: sizes, rowHeight: rowHeight, groupSpacing: groupSpacing).last?.last else {
      return rowHeight
    }

    return last + rowHeight
  }

  override func draw(_ dirtyRect: NSRect) {
    guard groups.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }

    context.textMatrix = .identity
    context.setFillColor(NSColor.secondaryLabelColor.cgColor)
    missing.draw(at: CGPoint(x: 0, y: (bounds.height - style.captionFont.capHeight) / 2), in: context)
  }
}

final class CoreRowView: NSView {
  let name: String
  let bar: LevelBar
  private let label: TextLine
  private let style: DetailStyle

  init(name: String, style: DetailStyle) {
    self.name = name
    self.bar = LevelBar(style: style)
    self.label = TextLine(name, font: style.labelFont)
    self.style = style

    super.init(frame: NSRect(x: 0, y: 0, width: style.contentWidth, height: style.coreRowHeight))

    bar.frame = NSRect(
      x: style.coreBarStart,
      y: (style.coreRowHeight - style.barHeight) / 2,
      width: style.contentWidth - style.coreBarStart,
      height: style.barHeight
    )

    addSubview(bar)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("CoreRowView is not loaded from a nib")
  }

  func show(share: Double?, isStale: Bool) {
    bar.show(share.map { DetailRow.Value(amount: Int($0.rounded()), unit: .percent) }, isStale: isStale)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }

    context.textMatrix = .identity
    context.setFillColor(NSColor.labelColor.cgColor)
    label.draw(at: CGPoint(x: 0, y: (bounds.height - style.labelFont.capHeight) / 2), in: context)
  }
}
