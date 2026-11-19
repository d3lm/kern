import AppKit
import Testing

/// Gives up after 600 checks, which take a few seconds while the main thread is free. The wait counts checks,
/// not seconds, because every main-actor test shares the main thread, and while other tests keep it busy the
/// condition can neither become true nor be checked.
@MainActor
func waitUntil(
  _ condition: () -> Bool,
  sourceLocation: SourceLocation = #_sourceLocation
) async {
  for _ in 0..<600 {
    if condition() { return }

    try? await Task.sleep(for: .milliseconds(5))
  }

  if !condition() {
    Issue.record("condition still false after 600 checks", sourceLocation: sourceLocation)
  }
}

/// Draws at `scale` pixels per point whatever the display's scale, because checks sample rectangles half a point high,
/// which hold no pixel on a display at 1x such as a CI runner's.
@MainActor
func rendered(_ view: NSView, scale: CGFloat = 2) -> NSBitmapImageRep {
  let bitmap = emptyBitmap(size: view.bounds.size, scale: scale)

  view.cacheDisplay(in: view.bounds, to: bitmap)

  return bitmap
}

func rendered(_ image: NSImage, scale: CGFloat = 2) -> NSBitmapImageRep {
  let bitmap = emptyBitmap(size: image.size, scale: scale)

  NSGraphicsContext.saveGraphicsState()

  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

  image.draw(in: NSRect(origin: .zero, size: image.size))

  NSGraphicsContext.restoreGraphicsState()

  return bitmap
}

private func emptyBitmap(size: NSSize, scale: CGFloat) -> NSBitmapImageRep {
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width * scale),
    pixelsHigh: Int(size.height * scale),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
  )!

  bitmap.size = size

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
