import AppKit
import Testing

@MainActor
func waitUntil(
  timeout: Duration = .seconds(3),
  _ condition: () -> Bool,
  sourceLocation: SourceLocation = #_sourceLocation
) async {
  let deadline = ContinuousClock.now + timeout

  while !condition() {
    guard ContinuousClock.now < deadline else {
      Issue.record("condition still false after \(timeout)", sourceLocation: sourceLocation)
      return
    }

    try? await Task.sleep(for: .milliseconds(5))
  }
}

func rendered(_ image: NSImage, scale: CGFloat = 2) -> NSBitmapImageRep {
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(image.size.width * scale),
    pixelsHigh: Int(image.size.height * scale),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
  )!

  bitmap.size = image.size

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

  image.draw(in: NSRect(origin: .zero, size: image.size))

  NSGraphicsContext.restoreGraphicsState()

  return bitmap
}

extension NSBitmapImageRep {
  func pixels(in rect: NSRect) -> [NSColor] {
    let scale = CGFloat(pixelsWide) / size.width
    let columns = Int((rect.minX * scale).rounded())..<Int((rect.maxX * scale).rounded())
    let rows = Int(((size.height - rect.maxY) * scale).rounded())..<Int(((size.height - rect.minY) * scale).rounded())

    return columns.flatMap { x in rows.map { y in colorAt(x: x, y: y)! } }
  }

  func ink(in rect: NSRect) -> CGFloat {
    pixels(in: rect).map(\.alphaComponent).max() ?? 0
  }
}
