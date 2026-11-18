import AppKit

/// Shows the Settings window's tabs as toolbar buttons of its own, because the toolbar of `NSTabViewController` tints
/// the chosen tab with the accent color, and Kern shows it in the label color on a gray background instead.
final class SettingsTabs: NSTabViewController {
  private var buttons: [Int: SettingsTabButton] = [:]

  override func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    let item = super.toolbar(toolbar, itemForItemIdentifier: itemIdentifier, willBeInsertedIntoToolbar: flag)

    guard let item, let index = tabViewItems.firstIndex(where: { $0.label == item.label }) else { return item }

    let tab = tabViewItems[index]

    let button = SettingsTabButton(title: tab.label, image: tab.image) { [weak self] in
      self?.selectedTabViewItemIndex = index
    }

    button.isSelected = index == selectedTabViewItemIndex
    buttons[index] = button
    item.view = button
    toolbar.displayMode = .iconOnly

    return item
  }

  /// Leaves the selection to the buttons, so that the toolbar draws no tinted selection of its own.
  override func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    []
  }

  override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
    super.tabView(tabView, didSelect: tabViewItem)

    for (index, button) in buttons {
      button.isSelected = index == selectedTabViewItemIndex
    }
  }
}

final class SettingsTabButton: NSView {
  private static let width: CGFloat = 72
  private static let height: CGFloat = 46
  private static let cornerRadius: CGFloat = 6
  private static let symbolPointSize: CGFloat = 17
  private static let gap: CGFloat = 2

  let title: String
  private let symbol = NSImageView()
  private let label: NSTextField
  private let onClick: () -> Void

  var isSelected = false {
    didSet { showSelection() }
  }

  init(title: String, image: NSImage?, onClick: @escaping () -> Void) {
    self.title = title
    self.onClick = onClick
    label = NSTextField(labelWithString: title)

    super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))

    wantsLayer = true
    symbol.image = image
    symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Self.symbolPointSize, weight: .regular)

    symbol.sizeToFit()

    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

    label.sizeToFit()

    let top = ((Self.height - symbol.frame.height - Self.gap - label.alignmentSize.height) / 2).rounded()

    symbol.setFrameOrigin(NSPoint(x: ((Self.width - symbol.frame.width) / 2).rounded(), y: top))

    label.setAlignmentOrigin(
      NSPoint(x: ((Self.width - label.alignmentSize.width) / 2).rounded(), y: symbol.frame.maxY + Self.gap))

    addSubview(symbol)
    addSubview(label)

    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: Self.width), heightAnchor.constraint(equalToConstant: Self.height),
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(.radioButton)
    setAccessibilityLabel(title)
    showSelection()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("SettingsTabButton is not loaded from a nib")
  }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    frame.contains(point) ? self : nil
  }

  /// Keeps a drag that starts on a tab from moving the window, as the toolbar lets it do on views by default.
  override var mouseDownCanMoveWindow: Bool { false }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {}

  override func mouseUp(with event: NSEvent) {
    if bounds.contains(convert(event.locationInWindow, from: nil)) {
      onClick()
    }
  }

  override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
  override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }

  override func keyDown(with event: NSEvent) {
    if event.characters == " " || event.specialKey == .carriageReturn {
      onClick()
    } else {
      super.keyDown(with: event)
    }
  }

  override var focusRingMaskBounds: NSRect { bounds }

  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
  }

  override func accessibilityPerformPress() -> Bool {
    onClick()

    return true
  }

  override func updateLayer() {
    layer?.cornerRadius = Self.cornerRadius
    layer?.backgroundColor = isSelected ? NSColor.labelColor.withAlphaComponent(0.1).cgColor : nil
  }

  private func showSelection() {
    let color: NSColor = isSelected ? .labelColor : .secondaryLabelColor

    symbol.contentTintColor = color
    label.textColor = color

    setAccessibilityValue(isSelected ? 1 : 0)

    needsDisplay = true
  }
}
