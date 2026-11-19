import AppKit

/// Sends its action only when the user chooses another option, by a click, the arrow keys, or VoiceOver.
@MainActor
final class SlidingSegmentedControl: NSControl {
  static let height: CGFloat = 24
  private static let inset: CGFloat = 2
  private static let padding: CGFloat = 12
  private static let duration: TimeInterval = 0.2

  private static let thumbColor = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.2) : .white
  }

  let labels: [String]
  private let fields: [NSTextField]
  private let thumb = Thumb()
  private let segmentWidths: [CGFloat]
  private var selected = 0
  private var pressed: Int?
  private var segments: [Segment] = []

  init(labels: [String]) {
    self.labels = labels
    fields = labels.map { NSTextField(labelWithString: $0) }

    for field in fields {
      field.font = .systemFont(ofSize: NSFont.systemFontSize)
      field.alignment = .center

      field.sizeToFit()
    }

    segmentWidths = fields.map { $0.alignmentSize.width.rounded(.up) + 2 * Self.padding }

    super.init(frame: .zero)

    setFrameSize(NSSize(width: segmentWidths.reduce(0, +) + 2 * Self.inset, height: Self.height))

    wantsLayer = true

    addSubview(thumb)

    for (index, field) in fields.enumerated() {
      let frame = segmentFrame(index)

      field.frame = NSRect(
        x: frame.minX, y: ((Self.height - field.frame.height) / 2).rounded(), width: frame.width,
        height: field.frame.height)

      addSubview(field)
    }

    setAccessibilityElement(true)
    setAccessibilityRole(.radioGroup)

    segments = labels.indices.map { index in
      Segment(control: self, index: index, label: labels[index], frame: segmentFrame(index))
    }

    showSelection(animated: false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("SlidingSegmentedControl is not loaded from a nib")
  }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var intrinsicContentSize: NSSize { frame.size }

  /// Moves the thumb without sending the action.
  var selectedSegment: Int {
    get { selected }
    set {
      guard newValue != selected, labels.indices.contains(newValue) else { return }

      selected = newValue

      showSelection(animated: false)
    }
  }

  override func updateLayer() {
    layer?.cornerRadius = Self.height / 2
    layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
  }

  func segmentFrame(_ index: Int) -> NSRect {
    NSRect(
      x: Self.inset + segmentWidths[..<index].reduce(0, +), y: Self.inset, width: segmentWidths[index],
      height: Self.height - 2 * Self.inset)
  }

  var thumbFrame: NSRect { thumb.frame }

  private func showSelection(animated: Bool) {
    let frame = segmentFrame(selected)

    if animated, window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = Self.duration
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        thumb.animator().frame = frame
      }
    } else {
      thumb.frame = frame
    }

    for (index, field) in fields.enumerated() {
      field.textColor = index == selected ? .labelColor : .secondaryLabelColor
    }

    for (index, segment) in segments.enumerated() {
      segment.setAccessibilityValue(index == selected ? 1 : 0)
    }
  }

  /// Chooses `index` as the user does, sending the action when the choice changes.
  func choose(_ index: Int) {
    guard index != selected, labels.indices.contains(index) else { return }

    selected = index

    showSelection(animated: true)
    sendAction(action, to: target)
    NSAccessibility.post(element: self, notification: .valueChanged)
  }

  private func segment(at event: NSEvent) -> Int? {
    let point = convert(event.locationInWindow, from: nil)

    return labels.indices.first { segmentFrame($0).contains(point) }
  }

  override func mouseDown(with event: NSEvent) {
    pressed = segment(at: event)
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseUp(with event: NSEvent) {
    if let index = segment(at: event), index == pressed {
      choose(index)
    }

    pressed = nil
  }

  /// Takes the keyboard only with Full Keyboard Access, so that a click leaves no focus ring, as on other controls.
  override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
  override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }

  override func keyDown(with event: NSEvent) {
    switch event.specialKey {
    case .leftArrow?: choose(selected - 1)
    case .rightArrow?: choose(selected + 1)
    default: super.keyDown(with: event)
    }
  }

  override var focusRingMaskBounds: NSRect { bounds }

  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: bounds, xRadius: Self.height / 2, yRadius: Self.height / 2).fill()
  }

  override func accessibilityChildren() -> [Any]? {
    segments
  }

  private final class Thumb: NSView {
    override init(frame: NSRect) {
      super.init(frame: frame)

      wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("Thumb is not loaded from a nib")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
      guard let layer else { return }

      let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

      layer.cornerRadius = (SlidingSegmentedControl.height - 2 * SlidingSegmentedControl.inset) / 2
      layer.backgroundColor = SlidingSegmentedControl.thumbColor.cgColor
      layer.shadowColor = NSColor.black.cgColor
      layer.shadowOpacity = isDark ? 0 : 0.18
      layer.shadowRadius = 1.5
      layer.shadowOffset = CGSize(width: 0, height: -0.5)
    }
  }

  private final class Segment: NSAccessibilityElement {
    nonisolated(unsafe) private weak var control: SlidingSegmentedControl?
    private let index: Int

    init(control: SlidingSegmentedControl, index: Int, label: String, frame: NSRect) {
      self.control = control
      self.index = index

      super.init()

      setAccessibilityParent(control)
      setAccessibilityRole(.radioButton)
      setAccessibilityLabel(label)
      setAccessibilityFrameInParentSpace(frame)
    }

    /// AppKit asks for accessibility on the main thread.
    override func accessibilityPerformPress() -> Bool {
      let control = control
      let index = index

      return MainActor.assumeIsolated {
        control?.choose(index)

        return control != nil
      }
    }
  }
}
