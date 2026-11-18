import AppKit

/// A label's frame is larger than its text by a margin on each side, so views are lined up by their alignment
/// rectangles, which is where the text starts and ends.
extension NSView {
  var alignmentSize: NSSize {
    let insets = alignmentRectInsets

    return NSSize(width: frame.width - insets.left - insets.right, height: frame.height - insets.top - insets.bottom)
  }

  /// Assumes a flipped superview.
  func setAlignmentOrigin(_ origin: NSPoint) {
    setFrameOrigin(NSPoint(x: origin.x - alignmentRectInsets.left, y: origin.y - alignmentRectInsets.top))
  }
}
