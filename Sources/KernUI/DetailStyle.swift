import AppKit
import KernCore

struct DetailStyle {
  struct Gradient {
    let top: NSColor
    let bottom: NSColor
  }

  let contentWidth: CGFloat = 320
  let panelPadding: CGFloat = 14
  let panelCornerRadius: CGFloat = 16
  let panelGap: CGFloat = 4
  let screenMargin: CGFloat = 8
  let headerTop: CGFloat = 18
  let headerBottom: CGFloat = 12
  let headerSpacing: CGFloat = 6
  let cardPadding: CGFloat = 14
  let cardSpacing: CGFloat = 10
  let cardCornerRadius: CGFloat = 12
  let valueSpacing: CGFloat = 4
  let chartSpacing: CGFloat = 10
  let dividerSpacing: CGFloat = 12
  let rowSpacing: CGFloat = 10
  let captionSpacing: CGFloat = 2
  let footerSpacing: CGFloat = 12

  let titleFont = NSFont.systemFont(ofSize: 15, weight: .bold)
  let chipFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
  let headingFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
  let headingTracking: CGFloat = 0.6
  let bigValueFont = NSFont.monospacedDigitSystemFont(ofSize: 34, weight: .medium)
  let bigUnitFont = NSFont.systemFont(ofSize: 17)
  let labelFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
  let valueFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
  let captionFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
  let buttonFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

  let historyHeight: CGFloat = 44
  let temperatureHistoryHeight: CGFloat = 36
  let historyBarShare: CGFloat = 0.72
  let minimumBarHeight: CGFloat = 1
  let guideLevels = [50.0, 100]
  let guideDash: [CGFloat] = [2, 3]

  let coreTrack = CGSize(width: 6, height: 20)
  let coreCornerRadius: CGFloat = 3
  let coreSpacing: CGFloat = 4
  let coreLineSpacing: CGFloat = 6
  let coreGroupGap: CGFloat = 16
  let coreLabelSpacing: CGFloat = 8

  let barHeight: CGFloat = 4
  let barCornerRadius: CGFloat = 2
  let barStart: CGFloat = 96
  let rangeMinimumWidth: CGFloat = 6
  /// Wide enough for "888.8 / 888 GB", so the memory card's bars all end in the same place.
  let memoryValueWidth: CGFloat = 100
  let temperatureValueWidth: CGFloat = 44
  let valueGap: CGFloat = 12

  let buttonHeight: CGFloat = 28
  let buttonPadding: CGFloat = 10
  let buttonCornerRadius: CGFloat = 7
  let buttonHoverAlpha: CGFloat = 0.11
  let buttonPressedAlpha: CGFloat = 0.18

  /// Above it a temperature bar turns orange, and from `criticalCelsius` a sensor's range turns red.
  let hotCelsius = 80.0
  let criticalCelsius = 95.0

  let staleAlpha: CGFloat = 0.4
  let cardFillAlpha: CGFloat = 0.05
  let cardOutlineAlpha: CGFloat = 0.08
  let dividerAlpha: CGFloat = 0.08

  var cardWidth: CGFloat { contentWidth + 2 * cardPadding }
  var panelWidth: CGFloat { cardWidth + 2 * panelPadding }

  let cpuGradient = Gradient(
    top: dynamic(dark: rgb(0x64D2FF), light: rgb(0x5AC8FA)),
    bottom: dynamic(dark: rgb(0x0A84FF), light: rgb(0x007AFF))
  )

  let gpuGradient = Gradient(
    top: dynamic(dark: rgb(0xE0A3FF), light: rgb(0xD4A5F5)),
    bottom: dynamic(dark: rgb(0xBF5AF2), light: rgb(0xAF52DE))
  )

  let track = dynamic(dark: NSColor.white.withAlphaComponent(0.10), light: NSColor.black.withAlphaComponent(0.08))
  let guide = dynamic(dark: NSColor.white.withAlphaComponent(0.10), light: NSColor.black.withAlphaComponent(0.08))
  let coolBar = dynamic(dark: NSColor.white.withAlphaComponent(0.26), light: NSColor.black.withAlphaComponent(0.20))
  let hot = dynamic(dark: rgb(0xFF9F0A), light: rgb(0xB45309))
  let critical = dynamic(dark: rgb(0xFF453A), light: rgb(0xD70015))

  var used: NSColor { cpuGradient.bottom }

  func historyColor(celsius: Double) -> NSColor {
    celsius > hotCelsius ? hot : coolBar
  }

  func rangeColor(celsius: Double) -> NSColor {
    switch celsius {
    case criticalCelsius...: critical
    case hotCelsius...: hot
    default: coolBar
    }
  }
}

private func rgb(_ hex: Int) -> NSColor {
  NSColor(
    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
    green: CGFloat((hex >> 8) & 0xFF) / 255,
    blue: CGFloat(hex & 0xFF) / 255,
    alpha: 1
  )
}

private func dynamic(dark: NSColor, light: NSColor) -> NSColor {
  NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
  }
}
