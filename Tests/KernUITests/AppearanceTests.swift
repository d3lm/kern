import AppKit
import KernCore
import Testing

@testable import KernUI

@MainActor
struct AppearanceTests {
  let style = MenuBarStyle()

  func menuBarView(
    _ appearance: NSAppearance.Name,
    widgets: [Widget] = Widget.allCases,
    acquiredAt: ContinuousClock.Instant = .now,
    gpu: [MetricSample]? = nil,
    celsius: Double = 47,
    storage: Double = 50,
    kern: SampleState = usage(0.4, megabytes: 18)
  ) -> MenuBarView {
    let view = MenuBarView(layout: MenuBarLayout(widgets: widgets, unlabeled: [])!, temperatureUnit: .celsius)
    let cores = CoreUtilization(performance: [90, 70, 50, 30, 20, 10, 5, 0], efficiency: [60, 40])
    let cpu = (0..<60).map { sample(value(Double($0), cores: cores), at: acquiredAt) }

    view.appearance = NSAppearance(named: appearance)

    view.show(readings(.temperature, after: [sample(value(celsius, .celsius), at: acquiredAt)]), for: .temperature)
    view.show(readings(.cpu, after: cpu), for: .cpu)
    view.show(readings(.gpu, after: gpu ?? [sample(value(88), at: acquiredAt)]), for: .gpu)
    view.show(readings(.memoryPressure, after: [sample(value(64), at: acquiredAt)]), for: .memoryPressure)
    view.show(readings(.storage, after: [sample(value(storage), at: acquiredAt)]), for: .storage)
    view.show(readings(.kern, after: [sample(kern, at: acquiredAt)]), for: .kern)

    return view
  }

  static let inkScale: CGFloat = 4

  /// Returns, at four pixels per point, whether each pixel has ink, by column from the left and then by row from the
  /// top.
  func inkedPixels(of view: NSView) -> [[Bool]] {
    let bitmap = rendered(view, scale: Self.inkScale)

    return (0..<bitmap.pixelsWide).map { x in
      (0..<bitmap.pixelsHigh).map { y in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.25 }
    }
  }

  /// Returns the space between the ink of each widget and the next, which is what the eye compares.
  func inkGaps(in view: MenuBarView) -> [CGFloat] {
    let scale = Self.inkScale
    let inked = inkedPixels(of: view).map { $0.contains(true) }

    return zip(view.widgetViews, view.widgetViews.dropFirst()).map { left, right in
      let leftEnd = inked.indices.last { inked[$0] && CGFloat($0) < left.frame.maxX * scale } ?? 0
      let rightStart = inked.indices.first { inked[$0] && CGFloat($0) >= right.frame.minX * scale } ?? 0

      return CGFloat(rightStart - leftEnd - 1) / scale
    }
  }

  func valueFrame(of widget: Widget, in view: MenuBarView) -> NSRect {
    var frame = view[widget].frame

    let offset = style.valueOffset(label: widget.label)

    frame.origin.x += offset
    frame.size.width -= offset

    return frame
  }

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

  @Test(arguments: [
    (Widget.cpu, NSAppearance.Name.aqua), (.cpu, .vibrantLight), (.cpu, .darkAqua), (.cpu, .vibrantDark),
    (.cores, .aqua), (.cores, .vibrantDark),
  ])
  func chartWithoutValuesShowsOnlyAFaintOutline(widget: Widget, appearance: NSAppearance.Name) {
    let view = MenuBarView(layout: MenuBarLayout(widgets: [widget], showsLabels: false)!, temperatureUnit: .celsius)

    view.appearance = NSAppearance(named: appearance)

    view.show(readings(.cpu, after: [sample(failed)]), for: .cpu)

    let image = rendered(view)
    let inside = view[widget].frame.insetBy(dx: 2 * style.outlineWidth, dy: 2 * style.outlineWidth)

    #expect(view[widget].frame.width == style.chartWidth)
    #expect(image.ink(in: view[widget].frame) < 0.6)
    #expect(image.ink(in: inside) == 0)
  }

  /// Checks the bars against the design: 5 points wide and 1 point apart, 1 point inside the outline, and filled
  /// from the bottom of the 14 points inside it. A core at zero still fills one pixel.
  @Test func eachCoreIsABarFilledToItsLevelInsideTheOutline() {
    let view = MenuBarView(layout: MenuBarLayout(widgets: [.cores], showsLabels: false)!, temperatureUnit: .celsius)
    let levels: [Double] = [50, 100, 0, 50]
    let cores = CoreUtilization(performance: levels, efficiency: [])

    view.appearance = NSAppearance(named: .vibrantDark)

    view.show(readings(.cpu, after: [sample(value(50, cores: cores), at: .now)]), for: .cpu)

    let inked = inkedPixels(of: view)
    let scale = Self.inkScale
    let plot = style.outlineWidth + style.chartPadding

    func isInked(x: CGFloat, height: CGFloat) -> Bool {
      inked[Int(x * scale)][Int((style.height - height) * scale)]
    }

    #expect(view[.cores].content == .bars(levels, isStale: false))
    #expect(view.bounds.width == style.coresWidth(count: 4))

    for (index, level) in levels.enumerated() {
      let left = plot + CGFloat(index) * (style.coreBarWidth + style.coreBarSpacing)
      let top = 14 * level / 100

      for x in [left + 0.25, left + style.coreBarWidth / 2, left + style.coreBarWidth - 0.25] {
        #expect(isInked(x: x, height: plot + 0.1), "bar \(index) at its bottom, x \(x)")
        #expect(isInked(x: x, height: plot + top - 0.25) == (level > 0), "bar \(index) below its top, x \(x)")
        #expect(!isInked(x: x, height: plot + top + 0.5), "bar \(index) above its top, x \(x)")
      }

      if index < levels.count - 1 {
        #expect(!isInked(x: left + style.coreBarWidth + 0.5, height: plot + 0.1), "gap after bar \(index)")
      }
    }
  }

  /// The percentage is drawn right-aligned in a widget of whole points, as every reading is, so its ink starts
  /// after the gap by less than a point of rounding plus the side bearing of its first digit.
  @Test func storagePercentageFollowsItsGaugeAfterAGap() throws {
    let view = MenuBarView(layout: MenuBarLayout(widgets: [.storage], showsLabels: false)!, temperatureUnit: .celsius)

    view.appearance = NSAppearance(named: .vibrantDark)

    view.show(readings(.storage, after: [sample(value(50), at: .now)]), for: .storage)

    let inked = inkedPixels(of: view).map { $0.contains(true) }
    let scale = Self.inkScale
    let columns = inked.indices.filter { inked[$0] }.map { CGFloat($0) / scale }
    let text = try #require(columns.first { $0 >= style.gaugeWidth })

    #expect(view[.storage].content == .levelReading(.percent(50), isStale: false))
    #expect(columns.first == 0)
    #expect(columns.contains(style.gaugeWidth - 1 / scale))
    #expect(text >= style.gaugeWidth + style.gaugeTextSpacing)
    #expect(text <= style.gaugeWidth + style.gaugeTextSpacing + 2)
    #expect((view.bounds.width - 1.5..<view.bounds.width).contains(columns.last!))
  }

  @Test func unavailableGaugeShowsADashAndZeroFillsOnlyTheBottom() {
    let unavailable = menuBarView(.vibrantDark, gpu: [sample(failed)])
    let zero = menuBarView(.vibrantDark, gpu: [sample(value(0), at: .now)])
    let gauge = valueFrame(of: .gpu, in: unavailable)
    let middle = NSRect(x: gauge.minX + style.gaugeWidth / 2 - 0.5, y: gauge.midY - 0.25, width: 1, height: 0.5)
    let bottom = NSRect(x: gauge.minX + style.gaugeWidth / 2 - 0.5, y: gauge.minY, width: 1, height: 0.5)

    #expect(unavailable[.gpu].content == .level(.unavailable, isStale: false))
    #expect(rendered(unavailable).ink(in: middle) > 0.8)
    #expect(rendered(unavailable).ink(in: bottom) < 0.5)
    #expect(rendered(zero).ink(in: middle) < 0.5)
    #expect(rendered(zero).ink(in: bottom) > 0.8)
  }

  @Test func measuringGaugeIsOnlyItsTrack() {
    let measuring = menuBarView(.vibrantDark, gpu: [sample(.unavailable(.noValue(.awaitingBaseline)))])
    let gauge = valueFrame(of: .gpu, in: measuring)
    let middle = NSRect(x: gauge.minX + style.gaugeWidth / 2 - 0.5, y: gauge.midY - 0.25, width: 1, height: 0.5)
    let image = rendered(measuring)

    #expect(measuring[.gpu].content == .level(.measuring, isStale: false))
    #expect(image.ink(in: middle) < 0.5)
    #expect(image.ink(in: middle) > 0)
  }

  @Test(arguments: [Widget.temperature, .kern])
  func dashOfAWidgetWithoutAReadingIsInTheMiddleOfTheWidget(widget: Widget) throws {
    let view = MenuBarView(layout: MenuBarLayout(widgets: [widget], unlabeled: [])!, temperatureUnit: .celsius)

    view.appearance = NSAppearance(named: .vibrantDark)

    view.show(readings(widget.metric, after: [sample(failed)]), for: widget.metric)

    let inked = inkedPixels(of: view)
    let columns = inked.indices.filter { inked[$0].contains(true) }
    let rows = inked[0].indices.filter { row in inked.contains { $0[row] } }
    let left = try #require(columns.first)
    let right = try #require(columns.last)
    let top = try #require(rows.first)
    let bottom = try #require(rows.last)
    let pixel = 1 / Self.inkScale

    #expect(view[widget].content == .noReading)
    #expect(abs(CGFloat(left + right + 1) / 2 * pixel - view.bounds.midX) <= pixel, "horizontally")
    #expect(abs(CGFloat(top + bottom + 1) / 2 * pixel - view.bounds.midY) <= pixel, "vertically")
  }

  /// Text keeps its glyphs' side bearings, up to 1.8 points for a leading 1, and a widget is a whole number of points
  /// wide, so a gap next to text may be up to 4 points wider than one between a chart and a gauge.
  @Test(arguments: [
    [Widget.temperature, .kern, .cpu, .gpu, .memory], [.kern, .temperature, .cpu, .memory], [.cpu, .temperature, .gpu],
    [.gpu, .kern, .memory], [.storage, .cores, .temperature, .memory], [.cores, .storage, .kern, .gpu],
  ])
  func everyGapBetweenWidgetsLooksTheSameWhateverTheReadings(widgets: [Widget]) {
    let readings: [(Double, Double, SampleState)] = [
      (63, 7, usage(3.2, megabytes: 28)), (47, 50, usage(0.4, megabytes: 9)), (103, 100, usage(12, megabytes: 127)),
      (63, 41, failed),
    ]

    for (celsius, storage, kern) in readings {
      let view = menuBarView(.vibrantDark, widgets: widgets, celsius: celsius, storage: storage, kern: kern)
      let gaps = inkGaps(in: view)

      #expect(gaps.max()! - gaps.min()! <= 4, "\(celsius)° \(storage)% \(kern): \(gaps)")
    }
  }
}
