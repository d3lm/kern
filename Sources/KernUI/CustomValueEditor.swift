import AppKit

/// Asks for a value a `ChoicePopUp` does not list. Return or a click outside the popover applies the value, and
/// Escape closes it without applying anything. A value outside `range` moves to its nearest end, and text that is
/// not a number changes nothing.
@MainActor
final class CustomValueEditor: NSViewController, NSTextFieldDelegate, NSPopoverDelegate {
  private static let fieldWidth: CGFloat = 56
  private static let margin: CGFloat = 14
  private static let spacing: CGFloat = 6

  let field = NSTextField(string: "")
  let stepper = NSStepper()
  let popover = NSPopover()
  private let range: ClosedRange<Int>
  private let unit: String
  private let onApply: (Int) -> Void
  private var isCancelled = false

  init(value: Int, range: ClosedRange<Int>, unit: String, title: String, onApply: @escaping (Int) -> Void) {
    self.range = range
    self.unit = unit
    self.onApply = onApply

    super.init(nibName: nil, bundle: nil)

    field.integerValue = value
    field.alignment = .right
    field.bezelStyle = .roundedBezel
    field.delegate = self

    field.setAccessibilityLabel(title)

    stepper.minValue = Double(range.lowerBound)
    stepper.maxValue = Double(range.upperBound)
    stepper.integerValue = value
    stepper.valueWraps = false
    stepper.target = self
    stepper.action = #selector(step)

    stepper.setAccessibilityLabel(title)

    popover.behavior = .transient
    popover.delegate = self
    popover.contentViewController = self
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("CustomValueEditor is not loaded from a nib")
  }

  override func loadView() {
    let unitLabel = NSTextField(labelWithString: unit)
    let caption = NSTextField(labelWithString: "From \(range.lowerBound) to \(range.upperBound) \(unit).")
    let view = EditingView()

    caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    caption.textColor = .secondaryLabelColor

    for control in [field, unitLabel, stepper, caption] as [NSControl] {
      control.sizeToFit()
      view.addSubview(control)
    }

    let rowHeight = max(field.frame.height, stepper.frame.height)
    let center = { (control: NSView) in Self.margin + ((rowHeight - control.frame.height) / 2).rounded() }

    field.frame = NSRect(x: Self.margin, y: center(field), width: Self.fieldWidth, height: field.frame.height)

    stepper.setFrameOrigin(NSPoint(x: field.frame.maxX + 2, y: center(stepper)))
    unitLabel.setFrameOrigin(NSPoint(x: stepper.frame.maxX + Self.spacing, y: center(unitLabel)))
    caption.setAlignmentOrigin(NSPoint(x: Self.margin, y: Self.margin + rowHeight + Self.spacing))

    view.frame.size = NSSize(
      width: max(unitLabel.frame.maxX, caption.frame.maxX) + Self.margin, height: caption.frame.maxY + Self.margin)

    self.view = view

    preferredContentSize = view.frame.size
  }

  func show(below anchor: NSView) {
    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    field.window?.makeFirstResponder(field)
    field.currentEditor()?.selectAll(nil)
  }

  var value: Int? {
    Double(field.stringValue.trimmingCharacters(in: .whitespaces)).flatMap(range.nearest)
  }

  func controlTextDidChange(_ notification: Notification) {
    if let value { stepper.integerValue = value }
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.cancelOperation(_:)):
      cancelOperation(nil)
      return true
    case #selector(NSResponder.insertNewline(_:)):
      popover.performClose(nil)
      return true
    default:
      return false
    }
  }

  /// Takes Escape wherever the keyboard is in the popover, such as on the stepper with Full Keyboard Access.
  override func cancelOperation(_ sender: Any?) {
    isCancelled = true

    popover.performClose(nil)
  }

  func popoverWillClose(_ notification: Notification) {
    if !isCancelled, let value { onApply(value) }
  }

  /// The popover holds the editor as its content, so letting go of it lets both be released.
  func popoverDidClose(_ notification: Notification) {
    popover.contentViewController = nil
  }

  @objc private func step() {
    field.integerValue = stepper.integerValue
  }
}

/// Takes the editing shortcuts for the field, because Kern has no main menu with an Edit menu to take them,
/// and a popover is a window of its own, so the Settings window does not see its keys. It passes other shortcuts,
/// ⌘W and ⌘Q, on to the Settings window.
private final class EditingView: NSView {
  private static let actions: [String: Selector] = [
    "x": #selector(NSText.cut(_:)),
    "c": #selector(NSText.copy(_:)),
    "v": #selector(NSText.paste(_:)),
    "a": #selector(NSText.selectAll(_:)),
    "z": Selector(("undo:")),
  ]

  override var isFlipped: Bool { true }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let action: Selector? =
      switch event.shortcut {
      case (.command, let key?): Self.actions[key]
      case ([.command, .shift], "z"): Selector(("redo:"))
      default: nil
      }

    if let action, window?.firstResponder?.tryToPerform(action, with: self) == true {
      return true
    }

    if let settings = window?.parent, settings.performKeyEquivalent(with: event) {
      return true
    }

    return super.performKeyEquivalent(with: event)
  }
}
