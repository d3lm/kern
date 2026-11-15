import AppKit
import KernCore
import Testing

@testable import KernUI

/// Renders the menu bar the way AppKit draws it and inspects the pixels, so the colors are checked
/// as they come out, not as the code names them.
@MainActor
struct AppearanceTests {
  let style = MenuBarStyle()

  func menuBarView(
    _ appearance: NSAppearance.Name,
    acquiredAt: ContinuousClock.Instant = .now,
    gpu: [MetricSample]? = nil
  ) -> MenuBarView {
    let view = MenuBarView(layout: .standard)
    let cpu = (0..<60).map { sample(value(Double($0)), at: acquiredAt) }

    view.appearance = NSAppearance(named: appearance)
    view.show(readings(.temperature, after: [sample(value(47, .celsius), at: acquiredAt)]), for: .temperature)
    view.show(readings(.cpu, after: cpu), for: .cpu)
    view.show(readings(.gpu, after: gpu ?? [sample(value(88), at: acquiredAt)]), for: .gpu)
    view.show(readings(.memory, after: [sample(value(64), at: acquiredAt)]), for: .memory)

    return view
  }

  func rendered(_ view: NSView) -> NSBitmapImageRep {
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!

    view.cacheDisplay(in: view.bounds, to: bitmap)

    return bitmap
  }

  /// Where the widget's value is drawn, after its label.
  func valueFrame(of widget: Widget, in view: MenuBarView) -> NSRect {
    var frame = view[widget].frame
    let offset = style.valueOffset(label: widget.label)

    frame.origin.x += offset
    frame.size.width -= offset

    return frame
  }

  /// The brightness of the most opaque pixel inside `rect`, which is where something is drawn at full strength.
  func brightness(in rect: NSRect, of image: NSBitmapImageRep) -> CGFloat {
    let strongest = image.pixels(in: rect).max { $0.alphaComponent < $1.alphaComponent }!.usingColorSpace(.deviceRGB)!

    return (strongest.redComponent + strongest.greenComponent + strongest.blueComponent) / 3
  }

  @Test(arguments: [NSAppearance.Name.aqua, .vibrantLight])
  func widgetsAreDarkOnALightMenuBar(appearance: NSAppearance.Name) {
    let view = menuBarView(appearance)
    let image = rendered(view)

    for widget in Widget.allCases {
      #expect(image.ink(in: valueFrame(of: widget, in: view)) > 0.5, "\(widget)")
      #expect(brightness(in: valueFrame(of: widget, in: view), of: image) < 0.25, "\(widget)")
    }
  }

  @Test(arguments: [NSAppearance.Name.darkAqua, .vibrantDark])
  func widgetsAreLightOnADarkMenuBar(appearance: NSAppearance.Name) {
    let view = menuBarView(appearance)
    let image = rendered(view)

    for widget in Widget.allCases {
      #expect(image.ink(in: valueFrame(of: widget, in: view)) > 0.5, "\(widget)")
      #expect(brightness(in: valueFrame(of: widget, in: view), of: image) > 0.75, "\(widget)")
    }
  }

  @Test(arguments: [NSAppearance.Name.aqua, .vibrantLight, .darkAqua, .vibrantDark])
  func staleValuesAreFainterThanCurrentOnes(appearance: NSAppearance.Name) {
    let current = menuBarView(appearance)
    let stale = menuBarView(appearance, acquiredAt: .now - .seconds(60))
    let currentImage = rendered(current)
    let staleImage = rendered(stale)

    #expect(stale.widgetViews.allSatisfy { $0.content?.isStale == true })

    for widget in Widget.allCases {
      let frame = valueFrame(of: widget, in: current)

      #expect(staleImage.ink(in: frame) < currentImage.ink(in: frame) * 0.75, "\(widget)")
    }
  }

  @Test(arguments: [NSAppearance.Name.aqua, .vibrantLight, .darkAqua, .vibrantDark])
  func chartWithoutValuesShowsOnlyAFaintOutline(appearance: NSAppearance.Name) {
    let view = MenuBarView(layout: MenuBarLayout(widgets: [.cpu], showsLabels: false)!)

    view.appearance = NSAppearance(named: appearance)
    view.show(readings(.cpu, after: [sample(failed)]), for: .cpu)

    let image = rendered(view)
    let inside = view[.cpu].frame.insetBy(dx: 2 * style.outlineWidth, dy: 2 * style.outlineWidth)

    #expect(image.ink(in: view[.cpu].frame) < 0.6)
    #expect(image.ink(in: inside) == 0)
  }

  /// A gauge with no level must not look like a gauge at zero, or an unavailable reading would pass for an idle GPU.
  @Test func unavailableGaugeShowsADashAndZeroFillsOnlyTheBottom() {
    let unavailable = menuBarView(.vibrantDark, gpu: [sample(failed)])
    let zero = menuBarView(.vibrantDark, gpu: [sample(value(0))])
    let gauge = valueFrame(of: .gpu, in: unavailable)
    let middle = NSRect(x: gauge.minX + style.gaugeWidth / 2 - 0.5, y: gauge.midY - 0.25, width: 1, height: 0.5)
    let bottom = NSRect(x: gauge.minX + style.gaugeWidth / 2 - 0.5, y: gauge.minY, width: 1, height: 0.5)

    #expect(unavailable[.gpu].content == .level(nil, isStale: false))
    #expect(rendered(unavailable).ink(in: middle) > 0.8)
    #expect(rendered(unavailable).ink(in: bottom) < 0.5)
    #expect(rendered(zero).ink(in: middle) < 0.5)
    #expect(rendered(zero).ink(in: bottom) > 0.8)
  }
}
