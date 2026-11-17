import AppKit
import KernCore

/// AppKit draws a view larger than about 36,000 square points (190 by 190) with Metal, which permanently costs
/// several MiB, so large shapes must be layer properties. Views are placed by frame, not Auto Layout, because
/// malloc keeps part of what Auto Layout allocates on each opening.
final class DetailView: NSView {
  let sections: [DetailSection]
  let cards: [DetailCard]
  let header: DetailHeader
  let settingsButton: FooterButton
  let quitButton: FooterButton
  var fittingSizeChanged: () -> Void = {}
  private let style: DetailStyle
  private var size = NSSize.zero

  init(sources: [Metric: MetricSource], chip: String? = nil, style: DetailStyle = DetailStyle()) {
    sections = Metric.detailOrder.compactMap { metric in
      sources[metric].map { DetailSection(metric: metric, source: $0, style: style) }
    }

    var cards: [DetailCard] = []

    for section in sections {
      if let card = cards.last, card.heading == section.metric.detailHeading {
        card.add(section.lines)
      } else {
        cards.append(
          DetailCard(heading: section.metric.detailHeading, info: section.info, lines: section.lines, style: style))
      }
    }

    self.cards = cards
    self.header = DetailHeader(chip: chip, style: style)
    self.style = style

    settingsButton = FooterButton(title: "Settings", symbol: "gearshape", style: style)
    settingsButton.isEnabled = false

    quitButton = FooterButton(title: "Quit", style: style)
    quitButton.target = NSApp
    quitButton.action = #selector(NSApplication.terminate(_:))
    quitButton.setAccessibilityLabel("Quit Kern")

    super.init(frame: .zero)

    for view in [header] + cards + [settingsButton, quitButton] {
      addSubview(view)
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
    let left = style.panelPadding
    var top = style.headerTop

    header.setFrameOrigin(NSPoint(x: left + style.cardPadding, y: top))
    top = header.frame.maxY + style.headerBottom

    for card in cards {
      card.arrange()
      card.setFrameOrigin(NSPoint(x: left, y: top))
      top = card.frame.maxY + style.cardSpacing
    }

    top += style.footerSpacing - style.cardSpacing

    settingsButton.setFrameOrigin(NSPoint(x: left, y: top))
    quitButton.setFrameOrigin(NSPoint(x: left + style.cardWidth - quitButton.frame.width, y: top))

    let size = NSSize(width: style.panelWidth, height: top + style.buttonHeight + style.panelPadding)

    if size != self.size {
      self.size = size
      fittingSizeChanged()
    }
  }
}

/// A part of a card, and what kind of part it is, which sets the space above it.
struct DetailLine {
  enum Kind {
    case value
    case chart
    case divider
    case row
  }

  let view: NSView
  let kind: Kind
}

/// One metric's parts of its card, and keeping them up to date with its readings.
@MainActor
final class DetailSection {
  let metric: Metric
  let value: DetailValueView?
  let history: HistoryChartView?
  let cores: CoreChartView?
  let sensors: SensorListView?
  let bar: BarRowView?
  let info: String?
  let lines: [DetailLine]
  var changed: () -> Void = {}
  private let source: MetricSource
  private let style: DetailStyle
  private var readings: MetricReadings?
  private lazy var staleCheck = StaleCheck { [weak self] in self?.markStale() }

  init(metric: Metric, source: MetricSource, style: DetailStyle) {
    let title = metric.detailTitle(measuring: source.quantity)

    self.metric = metric
    self.source = source
    self.style = style

    value =
      metric == .memory
      ? nil : DetailValueView(caption: metric.detailCaption(measuring: source.quantity), style: style)

    history =
      switch metric {
      case .cpu, .memoryPressure: HistoryChartView(title: title, fill: .gradient(style.cpuGradient), style: style)
      case .gpu: HistoryChartView(title: title, fill: .gradient(style.gpuGradient), style: style)
      case .temperature: HistoryChartView(title: title, fill: .temperature, style: style)
      case .memory: nil
      }

    cores = metric == .cpu ? CoreChartView(title: title, kinds: source.coreKinds, style: style) : nil
    sensors = metric == .temperature ? SensorListView(style: style) : nil
    bar = metric == .memory ? BarRowView(valueWidth: style.memoryValueWidth, style: style) : nil
    info = metric == .gpu || metric == .temperature ? metric.detailExplanation(of: source) : nil

    let parts: [DetailLine?] = [
      value.map { DetailLine(view: $0, kind: .value) },
      history.map { DetailLine(view: $0, kind: .chart) },
      cores.map { DetailLine(view: $0, kind: .row) },
      sensors.map { DetailLine(view: $0, kind: .row) },
      bar.map { DetailLine(view: $0, kind: .row) },
    ]

    lines = parts.compactMap { $0 }
  }

  func show(_ readings: MetricReadings) {
    let now = ContinuousClock.now
    let row = metric.detailRow(for: readings, source: source, at: now)

    self.readings = readings

    value?.show(row, at: now)
    history?.show(metric.historyChart(for: readings, at: now))
    cores?.show(metric.coreChart(for: readings, at: now))
    bar?.show(usedMemoryRow(for: row, readings: readings, at: now))

    sensors?.show(
      (readings.lastSuccessful?.value?.temperatures ?? []).map(SensorRange.init),
      isStale: row.isStale,
      help: source.description
    )

    staleCheck.schedule(at: row.isStale ? nil : readings.staleAt)
    changed()
  }

  private func markStale() {
    if let readings {
      show(readings)
    }
  }

  private func usedMemoryRow(for row: DetailRow, readings: MetricReadings, at now: ContinuousClock.Instant) -> BarRow {
    let memory = readings.lastSuccessful?.value?.memory.map(MemoryText.init)
    let status = row.statusText(at: now, date: .now, timeStyle: DetailValueView.timeStyle)

    return BarRow(
      label: row.label,
      fill: row.value.map { 0...$0.fraction },
      color: style.used,
      value: memory?.used ?? row.valueText,
      valueDetail: memory.map { " / \($0.installed) GB" } ?? "",
      spokenValue: ["\(row.title), \(memory?.spokenText ?? row.spokenValue)", status].compactMap { $0 }
        .joined(separator: ". "),
      status: status,
      help: row.explanation,
      isStale: row.isStale
    )
  }
}

final class DetailHeader: NSView {
  let title: NSTextField
  let chip: NSTextField?

  init(chip: String?, style: DetailStyle) {
    title = NSTextField(labelWithString: "Kern")
    self.chip = chip.map { NSTextField(labelWithString: $0) }

    super.init(frame: .zero)

    title.font = style.titleFont
    title.sizeToFit()
    title.setAlignmentOrigin(.zero)
    addSubview(title)

    if let field = self.chip {
      field.font = style.chipFont
      field.textColor = .secondaryLabelColor
      field.sizeToFit()
      field.setAlignmentOrigin(
        NSPoint(
          x: title.alignmentSize.width + style.headerSpacing,
          y: title.firstBaselineOffsetFromTop - field.firstBaselineOffsetFromTop))

      addSubview(field)
    }

    setFrameSize(NSSize(width: style.contentWidth, height: title.alignmentSize.height))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("DetailHeader is not loaded from a nib")
  }

  override var isFlipped: Bool { true }
}

final class DetailCard: NSView {
  let heading: String
  private let style: DetailStyle
  private let title: NSTextField
  private let infoIcon: NSImageView?
  private var lines: [DetailLine] = []

  init(heading: String, info: String?, lines: [DetailLine], style: DetailStyle) {
    self.heading = heading
    self.style = style

    title = NSTextField(
      labelWithAttributedString: NSAttributedString(
        string: heading.uppercased(),
        attributes: [
          .font: style.headingFont, .foregroundColor: NSColor.secondaryLabelColor, .kern: style.headingTracking,
        ]))

    infoIcon = info.map { info in
      let icon = NSImageView(
        image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil) ?? NSImage())

      icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: style.headingFont.pointSize, weight: .regular)
      icon.contentTintColor = .secondaryLabelColor
      icon.toolTip = info
      icon.setAccessibilityElement(false)
      icon.sizeToFit()

      return icon
    }

    super.init(frame: .zero)

    title.setAccessibilityLabel(heading)
    title.sizeToFit()

    wantsLayer = true
    addSubview(title)

    if let infoIcon {
      addSubview(infoIcon)
    }

    add(lines)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("DetailCard is not loaded from a nib")
  }

  override var isFlipped: Bool { true }

  /// Rows below a chart are set apart from it by a divider.
  func add(_ lines: [DetailLine]) {
    for line in lines {
      if line.kind == .row, self.lines.last?.kind == .chart {
        let divider = DetailLine(view: DividerView(style: style), kind: .divider)

        self.lines.append(divider)
        addSubview(divider.view)
      }

      self.lines.append(line)
      addSubview(line.view)
    }
  }

  func arrange() {
    let padding = style.cardPadding
    let headingHeight = title.alignmentSize.height
    var top = padding + headingHeight

    title.setAlignmentOrigin(NSPoint(x: padding, y: padding))

    infoIcon?.setAlignmentOrigin(
      NSPoint(
        x: padding + title.alignmentSize.width + style.headerSpacing,
        y: padding + (headingHeight - (infoIcon?.alignmentSize.height ?? 0)) / 2))

    var previous: DetailLine.Kind?

    for (index, line) in lines.enumerated() {
      if line.kind == .divider {
        line.view.isHidden = index + 1 < lines.count ? lines[index + 1].view.isHidden : true
      }

      guard !line.view.isHidden else { continue }

      let spacing =
        switch line.kind {
        case .value: style.valueSpacing
        case .chart: style.chartSpacing
        case .divider: style.dividerSpacing
        case .row: previous == .divider ? style.dividerSpacing : style.rowSpacing
        }

      line.view.setFrameOrigin(NSPoint(x: padding, y: top + spacing))
      top = line.view.frame.maxY
      previous = line.kind
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

/// A metric's large number, with what it measures beside it and, below it, the status of a value that is not current.
final class DetailValueView: NSView {
  static let timeStyle = Date.FormatStyle(date: .omitted, time: .standard)

  private let style: DetailStyle
  private let number: NSTextField
  private let unit: NSTextField
  private let caption: NSTextField?
  private let status: NSTextField
  private(set) var content: DetailRow?

  init(caption: String?, style: DetailStyle) {
    self.style = style
    number = NSTextField(labelWithString: "")
    unit = NSTextField(labelWithString: "")
    self.caption = caption.map { NSTextField(labelWithString: $0) }
    status = NSTextField(wrappingLabelWithString: "")

    super.init(frame: .zero)

    number.font = style.bigValueFont
    status.font = style.captionFont
    status.textColor = .secondaryLabelColor
    status.isSelectable = false

    if let caption = self.caption {
      caption.font = style.captionFont
      caption.textColor = .secondaryLabelColor
      caption.sizeToFit()
    }

    for view in [number, unit, status] + [self.caption].compactMap({ $0 }) {
      view.setAccessibilityElement(false)
      addSubview(view)
    }

    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    arrange()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("DetailValueView is not loaded from a nib")
  }

  override var isFlipped: Bool { true }

  var valueText: String { number.stringValue + unit.stringValue }
  var statusText: String { status.isHidden ? "" : status.stringValue }

  func show(_ content: DetailRow, at now: ContinuousClock.Instant) {
    guard content != self.content else { return }

    self.content = content

    let statusText = content.statusText(at: now, date: .now, timeStyle: Self.timeStyle)
    let isCelsius = content.value?.unit == .celsius

    number.stringValue = content.numberText
    number.textColor = content.isStale ? .tertiaryLabelColor : .labelColor
    unit.stringValue = content.unitText
    unit.font = isCelsius ? style.bigValueFont : style.bigUnitFont
    unit.textColor = content.isStale ? .tertiaryLabelColor : isCelsius ? .labelColor : .secondaryLabelColor
    status.stringValue = statusText ?? ""
    status.isHidden = statusText == nil
    toolTip = content.explanation

    setAccessibilityValue(
      ["\(content.title), \(content.spokenValue)", statusText].compactMap { $0 }.joined(separator: ". "))

    setAccessibilityHelp(content.explanation)
    arrange()
  }

  private func arrange() {
    number.sizeToFit()
    unit.sizeToFit()
    number.setAlignmentOrigin(.zero)

    let baseline = number.firstBaselineOffsetFromTop
    let unitGap: CGFloat = content?.value?.unit == .percent ? 3 : 0

    unit.setAlignmentOrigin(
      NSPoint(x: number.alignmentSize.width + unitGap, y: baseline - unit.firstBaselineOffsetFromTop))

    caption?.setAlignmentOrigin(
      NSPoint(
        x: style.contentWidth - (caption?.alignmentSize.width ?? 0),
        y: baseline - (caption?.firstBaselineOffsetFromTop ?? 0)))

    var top = number.alignmentSize.height

    if !status.isHidden {
      top += status.place(below: top, width: style.contentWidth, spacing: style.captionSpacing)
    }

    setFrameSize(NSSize(width: style.contentWidth, height: top))
  }
}

struct BarRow: Equatable {
  let label: String
  /// The filled part of the track, as fractions of its length.
  let fill: ClosedRange<Double>?
  let color: NSColor
  let value: String
  let valueDetail: String
  let spokenValue: String
  let status: String?
  let help: String?
  let isStale: Bool
}

/// A name, a thin bar, and a value on one line, with the status of a value that is not current below them.
final class BarRowView: NSView {
  private let style: DetailStyle
  private let valueWidth: CGFloat
  private let label: NSTextField
  private let value: NSTextField
  private let status: NSTextField
  let bar: LevelBar
  private(set) var content: BarRow?

  init(valueWidth: CGFloat, style: DetailStyle) {
    self.style = style
    self.valueWidth = valueWidth
    label = NSTextField(labelWithString: "")
    value = NSTextField(labelWithString: "")
    status = NSTextField(wrappingLabelWithString: "")
    bar = LevelBar(style: style)

    super.init(frame: .zero)

    label.font = style.labelFont
    value.alignment = .right
    status.font = style.captionFont
    status.textColor = .secondaryLabelColor
    status.isSelectable = false
    status.isHidden = true

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
    fatalError("BarRowView is not loaded from a nib")
  }

  override var isFlipped: Bool { true }

  var labelText: String { label.stringValue }
  var valueText: String { value.stringValue }
  var statusText: String { status.isHidden ? "" : status.stringValue }

  func show(_ content: BarRow) {
    guard content != self.content else { return }

    self.content = content

    let color: NSColor = content.isStale ? .tertiaryLabelColor : .labelColor

    label.stringValue = content.label

    value.attributedStringValue =
      NSAttributedString(
        string: content.value, attributes: [.font: style.valueFont, .foregroundColor: color])
      + NSAttributedString(
        string: content.valueDetail,
        attributes: [.font: style.labelFont, .foregroundColor: NSColor.secondaryLabelColor])

    bar.show(content.fill, color: content.color, isStale: content.isStale)
    status.stringValue = content.status ?? ""
    status.isHidden = content.status == nil
    toolTip = content.help
    setAccessibilityValue(content.spokenValue)
    setAccessibilityHelp(content.help)
    arrange()
  }

  private func arrange() {
    label.sizeToFit()
    value.sizeToFit()
    label.setAlignmentOrigin(.zero)

    value.setAlignmentOrigin(
      NSPoint(
        x: style.contentWidth - value.alignmentSize.width,
        y: label.firstBaselineOffsetFromTop - value.firstBaselineOffsetFromTop))

    let lineHeight = label.alignmentSize.height
    var top = lineHeight

    bar.frame = NSRect(
      x: style.barStart,
      y: (lineHeight - style.barHeight) / 2,
      width: style.contentWidth - valueWidth - style.valueGap - style.barStart,
      height: style.barHeight
    )

    if !status.isHidden {
      top += status.place(below: top, width: style.contentWidth, spacing: style.captionSpacing)
    }

    setFrameSize(NSSize(width: style.contentWidth, height: top))
  }
}

/// A row for each part of the chip whose sensors the temperature reads, with the range from coolest to hottest.
final class SensorListView: NSView {
  private let style: DetailStyle
  private(set) var rows: [BarRowView] = []

  init(style: DetailStyle) {
    self.style = style

    super.init(frame: NSRect(x: 0, y: 0, width: style.contentWidth, height: 0))

    isHidden = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("SensorListView is not loaded from a nib")
  }

  override var isFlipped: Bool { true }

  func show(_ ranges: [SensorRange], isStale: Bool, help: String) {
    while rows.count > ranges.count {
      rows.removeLast().removeFromSuperview()
    }

    while rows.count < ranges.count {
      let row = BarRowView(valueWidth: style.temperatureValueWidth, style: style)

      rows.append(row)
      addSubview(row)
    }

    var top: CGFloat = 0

    for (row, range) in zip(rows, ranges) {
      row.show(
        BarRow(
          label: range.label,
          fill: min(range.coolest / 100, 1)...min(range.hottest / 100, 1),
          color: style.rangeColor(celsius: range.hottest),
          value: range.valueText,
          valueDetail: "",
          spokenValue: range.spokenText,
          status: nil,
          help: help,
          isStale: isStale
        ))

      row.setFrameOrigin(NSPoint(x: 0, y: top))
      top = row.frame.maxY + style.rowSpacing
    }

    isHidden = rows.isEmpty
    setFrameSize(NSSize(width: style.contentWidth, height: max(0, top - style.rowSpacing)))
  }
}

final class DividerView: NSView {
  private let style: DetailStyle

  init(style: DetailStyle) {
    self.style = style

    super.init(frame: NSRect(x: 0, y: 0, width: style.contentWidth, height: 1))

    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("DividerView is not loaded from a nib")
  }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(style.dividerAlpha).cgColor
  }
}

final class FooterButton: NSButton {
  private let style: DetailStyle
  private(set) var isHovered = false
  private(set) var isPressed = false

  init(title: String, symbol: String? = nil, style: DetailStyle) {
    self.style = style

    super.init(frame: .zero)

    isBordered = false
    wantsLayer = true
    font = style.buttonFont

    attributedTitle = NSAttributedString(
      string: title, attributes: [.font: style.buttonFont, .foregroundColor: NSColor.labelColor])

    // the panel is never the key window, so the area must track the pointer in an inactive window too
    addTrackingArea(
      NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))

    if let symbol {
      image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      imagePosition = .imageLeading
      imageHugsTitle = true
      contentTintColor = .labelColor
    }

    sizeToFit()
    setFrameSize(NSSize(width: frame.width + 2 * style.buttonPadding, height: style.buttonHeight))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("FooterButton is not loaded from a nib")
  }

  override var isEnabled: Bool {
    didSet {
      alphaValue = isEnabled ? 1 : 0.45
      updateColors()
    }
  }

  override func mouseEntered(with event: NSEvent) {
    isHovered = true
    updateColors()
  }

  override func mouseExited(with event: NSEvent) {
    isHovered = false
    updateColors()
  }

  /// Tracks the click until the mouse-up, so it returns only once the press is over.
  override func mouseDown(with event: NSEvent) {
    isPressed = isEnabled
    updateColors()
    super.mouseDown(with: event)
    isPressed = false
    updateColors()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateColors()
  }

  var fillAlpha: CGFloat {
    switch (isEnabled, isPressed, isHovered) {
    case (true, true, _): style.buttonPressedAlpha
    case (true, false, true): style.buttonHoverAlpha
    default: style.cardFillAlpha
    }
  }

  private func updateColors() {
    guard let layer else { return }

    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer.cornerRadius = style.buttonCornerRadius
      layer.borderWidth = 1
      layer.backgroundColor = NSColor.labelColor.withAlphaComponent(fillAlpha).cgColor
      layer.borderColor = NSColor.labelColor.withAlphaComponent(style.cardOutlineAlpha).cgColor
    }
  }
}

extension NSAttributedString {
  fileprivate static func + (lhs: NSAttributedString, rhs: NSAttributedString) -> NSAttributedString {
    let joined = NSMutableAttributedString(attributedString: lhs)

    joined.append(rhs)

    return joined
  }
}

extension NSTextField {
  /// Lays out wrapping text below `top` across `width`, and returns the height it adds.
  fileprivate func place(below top: CGFloat, width: CGFloat, spacing: CGFloat) -> CGFloat {
    let insets = alignmentRectInsets
    let frameWidth = width + insets.left + insets.right
    let height = sizeThatFits(NSSize(width: frameWidth, height: .greatestFiniteMagnitude)).height

    setFrameSize(NSSize(width: frameWidth, height: height))
    setAlignmentOrigin(NSPoint(x: 0, y: top + spacing))

    return spacing + alignmentSize.height
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
