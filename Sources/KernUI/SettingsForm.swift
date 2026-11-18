import AppKit

/// Holds the look of a grouped settings form, which has a header above each rounded box and a footer below it.
///
/// Headers, row text, the lines between rows, footers, and the trailing controls all keep `inset` from the edge of the
/// box, measured to where their text or bezel starts, so that everything in a column lines up.
struct SettingsStyle {
  let width: CGFloat = 460
  let margin: CGFloat = 20
  let top: CGFloat = 20
  let bottom: CGFloat = 20
  let sectionSpacing: CGFloat = 20
  let headerGap: CGFloat = 6
  let footerSpacing: CGFloat = 12
  let inset: CGFloat = 10
  let rowHeight: CGFloat = 36
  let tallRowHeight: CGFloat = 50
  let subtitleGap: CGFloat = 2
  let accessorySpacing: CGFloat = 10
  let cornerRadius: CGFloat = 8
  let fillAlpha: CGFloat = 0.05
  let outlineAlpha: CGFloat = 0.08
  let separatorAlpha: CGFloat = 0.08

  let headerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
  let titleFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
  let subtitleFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
  let footerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize + 1)

  var boxWidth: CGFloat { width - 2 * margin }

  @MainActor
  func header(_ title: String) -> NSTextField {
    let header = NSTextField(
      labelWithAttributedString: NSAttributedString(
        string: title.uppercased(),
        attributes: [.font: headerFont, .foregroundColor: NSColor.secondaryLabelColor, .kern: 0.3]))

    header.setAccessibilityLabel(title)
    header.sizeToFit()

    return header
  }

  @MainActor
  func drawBox(on layer: CALayer?) {
    guard let layer else { return }

    layer.cornerRadius = cornerRadius
    layer.borderWidth = 1
    layer.backgroundColor = NSColor.labelColor.withAlphaComponent(fillAlpha).cgColor
    layer.borderColor = NSColor.labelColor.withAlphaComponent(outlineAlpha).cgColor
  }
}

/// Is the part of a section below its header, which takes the box's width and the height it needs.
@MainActor
protocol SettingsContent: NSView {
  func arrange()
}

/// Shows one tab of the Settings window. Its sections are stacked by frames, as the popover's cards are.
///
/// It takes the size its sections need when it is made, and after that only reports the size it needs, because the
/// tab view sizes it. Setting its own frame inside the tab view would fix its margins there and keep the window from
/// following.
final class SettingsForm: NSView {
  let sections: [SettingsSection]
  var sizeChanged: (NSSize) -> Void = { _ in }
  private(set) var size = NSSize.zero
  private let style: SettingsStyle

  init(_ sections: [SettingsSection], style: SettingsStyle) {
    self.sections = sections
    self.style = style

    super.init(frame: .zero)

    for section in sections {
      addSubview(section)
    }

    arrange()
    setFrameSize(size)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("SettingsForm is not loaded from a nib")
  }

  override var isFlipped: Bool { true }

  func arrange() {
    var top = style.top

    for section in sections {
      section.arrange()
      section.setFrameOrigin(NSPoint(x: style.margin, y: top))

      top = section.frame.maxY + style.sectionSpacing
    }

    let size = NSSize(width: style.width, height: top - style.sectionSpacing + style.bottom)

    if size != self.size {
      self.size = size

      sizeChanged(size)
    }
  }
}

final class SettingsSection: NSView {
  private static let infoGap: CGFloat = 4

  let header: NSTextField
  let infoButton: InfoButton?
  let content: any SettingsContent
  let footer: [NSView]
  private let style: SettingsStyle

  /// Puts an info button after the header when there is `info`, which explains the section in a popover, so that the
  /// form shows only the settings themselves. Stacks `footer` below the content, a button for example, lined up with
  /// the edge of the box rather than with the text inside it.
  init(
    _ title: String, info: String? = nil, content: any SettingsContent, footer: [NSView] = [], style: SettingsStyle
  ) {
    header = style.header(title)
    infoButton = info.map { InfoButton($0, about: title) }
    self.content = content
    self.footer = footer
    self.style = style

    super.init(frame: .zero)

    for view in [header, content] + [infoButton].compactMap(\.self) + footer {
      addSubview(view)
    }
  }

  convenience init(
    _ title: String, info: String? = nil, rows: [SettingsRow], footer: [NSView] = [], style: SettingsStyle
  ) {
    self.init(title, info: info, content: SettingsBox(rows: rows, style: style), footer: footer, style: style)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("SettingsSection is not loaded from a nib")
  }

  override var isFlipped: Bool { true }

  func arrange() {
    header.setAlignmentOrigin(NSPoint(x: style.inset, y: 0))

    if let infoButton {
      infoButton.setAlignmentOrigin(
        NSPoint(
          x: style.inset + header.alignmentSize.width + Self.infoGap,
          y: ((header.alignmentSize.height - infoButton.alignmentSize.height) / 2).rounded()))
    }

    content.arrange()
    content.setFrameOrigin(NSPoint(x: 0, y: header.alignmentSize.height + style.headerGap))

    var top = content.frame.maxY + style.sectionSpacing

    for view in footer {
      view.setFrameSize(view.fittingSize)

      view.setAlignmentOrigin(NSPoint(x: 0, y: top))

      top += view.alignmentSize.height + style.footerSpacing
    }

    setFrameSize(NSSize(width: style.boxWidth, height: footer.isEmpty ? content.frame.maxY : top - style.footerSpacing))
  }
}

final class InfoButton: NSButton, NSPopoverDelegate {
  private static let textWidth: CGFloat = 260
  private static let margin: CGFloat = 12

  let text: String
  private(set) var popover: NSPopover?
  /// Holds the number of the click on the button that closed the popover. A popover closes on the mouse-down outside
  /// it, and the button acts on the mouse-up of the same click, which would open the popover again.
  private var closingClick: Int?

  init(_ text: String, about title: String) {
    self.text = text

    super.init(frame: .zero)

    image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
    symbolConfiguration = NSImage.SymbolConfiguration(pointSize: NSFont.smallSystemFontSize, weight: .regular)
    imagePosition = .imageOnly
    isBordered = false
    contentTintColor = .secondaryLabelColor
    target = self
    action = #selector(showText)

    setAccessibilityLabel("About \(title)")
    setAccessibilityHelp(text)
    sizeToFit()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("InfoButton is not loaded from a nib")
  }

  @objc private func showText() {
    guard opens(on: NSApp.currentEvent) else { return }

    if let popover, popover.isShown {
      popover.performClose(nil)
      return
    }

    let label = NSTextField(wrappingLabelWithString: text)

    label.font = .systemFont(ofSize: NSFont.systemFontSize)
    label.preferredMaxLayoutWidth = Self.textWidth

    let size = label.fittingSize
    let controller = NSViewController()
    let popover = NSPopover()

    label.frame = NSRect(origin: NSPoint(x: Self.margin, y: Self.margin), size: size)

    controller.view = NSView(
      frame: NSRect(x: 0, y: 0, width: size.width + 2 * Self.margin, height: size.height + 2 * Self.margin))

    controller.view.addSubview(label)

    popover.behavior = .transient
    popover.delegate = self
    popover.contentViewController = controller

    popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)

    self.popover = popover
  }

  func popoverWillClose(_ notification: Notification) {
    noteClose(by: NSApp.currentEvent)
  }

  func noteClose(by event: NSEvent?) {
    guard let event, event.type == .leftMouseDown, event.window === window,
      bounds.contains(convert(event.locationInWindow, from: nil))
    else {
      closingClick = nil
      return
    }

    closingClick = event.eventNumber
  }

  func opens(on event: NSEvent?) -> Bool {
    defer { closingClick = nil }

    return closingClick == nil || event?.type != .leftMouseUp || event?.eventNumber != closingClick
  }
}

final class SettingsBox: NSView, SettingsContent {
  let rows: [SettingsRow]
  private var separators: [SettingsSeparator] = []
  private let style: SettingsStyle

  init(rows: [SettingsRow], style: SettingsStyle) {
    self.rows = rows
    self.style = style

    super.init(frame: .zero)

    wantsLayer = true

    for row in rows {
      addSubview(row)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("SettingsBox is not loaded from a nib")
  }

  override var isFlipped: Bool { true }

  func arrange() {
    let shown = rows.filter { !$0.isHidden }

    while separators.count < max(shown.count - 1, 0) {
      let separator = SettingsSeparator(style: style)

      separators.append(separator)
      addSubview(separator)
    }

    var top: CGFloat = 0

    for (index, row) in shown.enumerated() {
      if index > 0 {
        separators[index - 1].frame = NSRect(
          x: style.inset, y: top, width: style.boxWidth - 2 * style.inset, height: 1)
      }

      row.arrange()
      row.setFrameOrigin(NSPoint(x: 0, y: top))

      top = row.frame.maxY
    }

    for (index, separator) in separators.enumerated() {
      separator.isHidden = index >= shown.count - 1
    }

    setFrameSize(NSSize(width: style.boxWidth, height: top))
  }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    style.drawBox(on: layer)
  }
}

final class SettingsSeparator: NSView {
  private let style: SettingsStyle

  init(style: SettingsStyle) {
    self.style = style

    super.init(frame: .zero)

    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("SettingsSeparator is not loaded from a nib")
  }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(style.separatorAlpha).cgColor
  }
}

class SettingsRow: NSView {
  let titleField: NSTextField
  let subtitleField: NSTextField?
  let accessories: [NSView]
  let style: SettingsStyle

  init(_ title: String, subtitle: String? = nil, accessories: [NSView], style: SettingsStyle) {
    titleField = NSTextField(labelWithString: title)
    subtitleField = subtitle.map { NSTextField(labelWithString: $0) }
    self.accessories = accessories
    self.style = style

    super.init(frame: .zero)

    titleField.font = style.titleFont
    titleField.lineBreakMode = .byTruncatingTail
    subtitleField?.font = style.subtitleFont
    subtitleField?.textColor = .secondaryLabelColor
    subtitleField?.lineBreakMode = .byTruncatingTail

    for view in [titleField, subtitleField].compactMap({ $0 }) + accessories {
      addSubview(view)
    }

    for case let control as NSControl in accessories where control.accessibilityLabel() == nil {
      control.setAccessibilityLabel(title)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("SettingsRow is not loaded from a nib")
  }

  override var isFlipped: Bool { true }

  var subtitle: String {
    get { subtitleField?.stringValue ?? "" }
    set { subtitleField?.stringValue = newValue }
  }

  func arrange() {
    let height = subtitleField == nil ? style.rowHeight : style.tallRowHeight

    var trailing = style.boxWidth - style.inset

    for view in accessories.reversed() where !view.isHidden {
      view.setFrameSize(view.fittingSize)

      let size = view.alignmentSize

      view.setAlignmentOrigin(NSPoint(x: trailing - size.width, y: ((height - size.height) / 2).rounded()))

      trailing -= size.width + style.accessorySpacing
    }

    for field in [titleField, subtitleField].compactMap({ $0 }) {
      field.sizeToFit()

      let insets = field.alignmentRectInsets

      field.setFrameSize(
        NSSize(width: max(trailing - style.inset, 0) + insets.left + insets.right, height: field.frame.height))
    }

    let subtitleHeight = subtitleField.map { $0.alignmentSize.height + style.subtitleGap } ?? 0
    let textTop = ((height - titleField.alignmentSize.height - subtitleHeight) / 2).rounded()

    titleField.setAlignmentOrigin(NSPoint(x: style.inset, y: textTop))

    subtitleField?.setAlignmentOrigin(
      NSPoint(x: style.inset, y: textTop + titleField.alignmentSize.height + style.subtitleGap))

    setFrameSize(NSSize(width: style.boxWidth, height: height))
  }
}

final class ChoicePopUp: NSPopUpButton, NSMenuDelegate {
  static let off = -1
  static let custom = -2

  /// Tells the owner the tag of the chosen item, which is `off` for Off.
  var onChoice: (Int) -> Void = { _ in }
  /// Asks the owner for a value the pop-up does not list. The pop-up keeps showing the value in force meanwhile.
  var onCustom: () -> Void = {}
  /// Returns where the pointer is, in the window's coordinates, or nil while the window is not key, where controls show
  /// no hover.
  var pointerLocation: () -> NSPoint? = { nil }
  private var selected = 0

  init(title: String) {
    super.init(frame: .zero, pullsDown: false)

    pointerLocation = { [weak self] in
      guard let window = self?.window, window.isKeyWindow else { return nil }

      return window.mouseLocationOutsideOfEventStream
    }

    cell = ChoicePopUpCell(textCell: "", pullsDown: false)
    menu?.delegate = self
    target = self
    action = #selector(chose)

    setAccessibilityLabel(title)
  }

  private var indicatorCell: ChoicePopUpCell? { cell as? ChoicePopUpCell }

  /// Makes room for the arrows after the title of the chosen item, which AppKit's size leaves out, and for the
  /// highlight around both.
  override var intrinsicContentSize: NSSize {
    let size = super.intrinsicContentSize

    return NSSize(
      width: size.width + ChoicePopUpCell.indicatorWidth + ChoicePopUpCell.leadingPadding,
      height: max(size.height, ChoicePopUpCell.height))
  }

  /// Lines up the arrows, not the highlight around them, with the controls of the other rows.
  override var alignmentRectInsets: NSEdgeInsets {
    NSEdgeInsets(top: 0, left: 0, bottom: 0, right: ChoicePopUpCell.padding)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()

    for area in trackingAreas where area.owner === self {
      removeTrackingArea(area)
    }

    addTrackingArea(
      NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))

    needsDisplay = true
  }

  /// Reads whether the pointer is over the pop-up each time it draws, rather than keeping what the entered and exited
  /// events said. The open menu is a window of its own, so it takes the pointer from the pop-up while it is open, and
  /// a pop-up that resizes under a still pointer gets no event at all.
  override func draw(_ dirtyRect: NSRect) {
    indicatorCell?.isHovered = isUnderPointer

    super.draw(dirtyRect)
  }

  private var isUnderPointer: Bool {
    pointerLocation().map { bounds.contains(convert($0, from: nil)) } ?? false
  }

  override func mouseEntered(with event: NSEvent) {
    needsDisplay = true
  }

  override func mouseExited(with event: NSEvent) {
    needsDisplay = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("ChoicePopUp is not loaded from a nib")
  }

  private struct Entry: Equatable {
    let title: String
    let tag: Int
  }

  /// Lists `choices`, adding `selected` among them in order when it is not one of them, as a value written with
  /// `defaults` can be, and selects it. It keeps the items when they are the same, because every change of settings
  /// shows every pop-up again.
  func show(_ choices: [Int], title: (Int) -> String, selected: Int, offersOff: Bool) {
    let values = Set(choices + (selected == Self.off ? [] : [selected])).sorted()

    let items: [Entry?] =
      values.map { Entry(title: title($0), tag: $0) } + [nil, Entry(title: "Custom…", tag: Self.custom)]
      + (offersOff ? [nil, Entry(title: "Off", tag: Self.off)] : [])

    let shown = itemArray.map { $0.isSeparatorItem ? nil : Entry(title: $0.title, tag: $0.tag) }

    if shown != items {
      removeAllItems()

      for item in items {
        if let item {
          addItem(withTitle: item.title)

          lastItem?.tag = item.tag
        } else {
          menu?.addItem(.separator())
        }
      }
    }

    self.selected = selected

    selectItem(withTag: selected)
  }

  /// Keeps the pop-up highlighted exactly while its menu is open, and redraws it at once when the menu closes, with a
  /// highlight only when the pointer is over it. AppKit keeps the cell highlighted until the chosen item's action has
  /// run, which would show the pop-up highlighted for a moment after its menu is gone.
  func menuWillOpen(_ menu: NSMenu) {
    indicatorCell?.isMenuOpen = true

    display()
  }

  func menuDidClose(_ menu: NSMenu) {
    indicatorCell?.isMenuOpen = false
    indicatorCell?.isHovered = isUnderPointer

    display()
  }

  @objc private func chose() {
    defer { needsDisplay = true }

    guard selectedTag() != Self.custom else {
      selectItem(withTag: selected)
      onCustom()
      return
    }

    onChoice(selectedTag())
  }
}

/// Draws a pop-up as System Settings does, with its title and, after it, its arrows on a rounded background. While the
/// pointer is over the pop-up, and more while its menu is open, one rounded background takes the whole pop-up instead.
/// AppKit's pop-ups either draw a bezel around the title or leave the arrows bare.
final class ChoicePopUpCell: NSPopUpButtonCell {
  static let indicatorSize = NSSize(width: 16, height: 16)
  /// Holds the room the highlight leaves after the arrows.
  static let padding: CGFloat = 3
  /// Holds the room the highlight leaves before the title, besides AppKit's own inset.
  static let leadingPadding: CGFloat = 3
  static let height: CGFloat = 20
  static let indicatorAlpha: CGFloat = 0.14
  private static let indicatorRadius: CGFloat = 4
  private static let highlightRadius: CGFloat = 6
  private static let arrowWidth: CGFloat = 7
  private static let arrowHeight: CGFloat = 3.5
  private static let arrowGap: CGFloat = 3
  private static let arrowLineWidth: CGFloat = 1.5

  /// Holds the width the arrows take after the title, with the padding after them. AppKit's own inset after the title
  /// leaves the gap before them.
  static var indicatorWidth: CGFloat { indicatorSize.width + padding }

  var isHovered = false
  var isMenuOpen = false

  override init(textCell string: String, pullsDown pullDown: Bool) {
    super.init(textCell: string, pullsDown: pullDown)

    isBordered = false
    arrowPosition = .noArrow
    alignment = .right
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("ChoicePopUpCell is not loaded from a nib")
  }

  static let highlightAlpha: CGFloat = 0.22

  /// Returns the alpha of the highlight behind the whole pop-up. The open menu keeps it as it was under the pointer
  /// rather than making it brighter, because macOS fades a closing menu out over about 240 ms before it reports the
  /// close, and a brighter pop-up would show through the fading menu and then dim.
  var highlightAlpha: CGFloat {
    isMenuOpen || isHovered ? Self.highlightAlpha : 0
  }

  override func drawingRect(forBounds rect: NSRect) -> NSRect {
    var rect = super.drawingRect(forBounds: rect)

    rect.size.width -= Self.indicatorWidth

    return rect
  }

  func indicatorRect(forBounds rect: NSRect) -> NSRect {
    NSRect(
      x: rect.maxX - Self.padding - Self.indicatorSize.width,
      y: (rect.midY - Self.indicatorSize.height / 2).rounded(), width: Self.indicatorSize.width,
      height: Self.indicatorSize.height)
  }

  /// Returns the up and down chevrons centered in `box`. They are drawn as a path rather than with the
  /// `chevron.up.chevron.down` symbol, whose glyph sits below the middle of its image, so they have the same room on
  /// every side.
  static func arrows(in box: NSRect, flipped: Bool) -> NSBezierPath {
    let up: CGFloat = flipped ? -1 : 1
    let inner = arrowGap / 2
    let path = NSBezierPath()

    for direction in [up, -up] {
      path.move(to: NSPoint(x: box.midX - arrowWidth / 2, y: box.midY + direction * inner))
      path.line(to: NSPoint(x: box.midX, y: box.midY + direction * (inner + arrowHeight)))
      path.line(to: NSPoint(x: box.midX + arrowWidth / 2, y: box.midY + direction * inner))
    }

    path.lineWidth = arrowLineWidth
    path.lineCapStyle = .round
    path.lineJoinStyle = .round

    return path
  }

  override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
    let indicator = indicatorRect(forBounds: cellFrame)

    if highlightAlpha > 0 {
      NSColor.labelColor.withAlphaComponent(highlightAlpha).setFill()
      NSBezierPath(roundedRect: cellFrame, xRadius: Self.highlightRadius, yRadius: Self.highlightRadius).fill()
    } else {
      NSColor.labelColor.withAlphaComponent(Self.indicatorAlpha).setFill()
      NSBezierPath(roundedRect: indicator, xRadius: Self.indicatorRadius, yRadius: Self.indicatorRadius).fill()
    }

    NSColor.labelColor.setStroke()
    Self.arrows(in: indicator, flipped: controlView.isFlipped).stroke()

    drawInterior(withFrame: cellFrame, in: controlView)
  }
}

extension NSSwitch {
  func configureForSettings(target: AnyObject, action: Selector) {
    controlSize = .mini
    self.target = target
    self.action = action
  }
}
