import AppKit

struct TextLine {
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

  func draw(at point: CGPoint, in context: CGContext) {
    context.textPosition = point

    CTLineDraw(line, context)
  }
}
