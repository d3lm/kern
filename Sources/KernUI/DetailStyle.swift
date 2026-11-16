import AppKit
import KernCore

struct DetailStyle {
  let contentWidth: CGFloat = 268
  let cardPadding: CGFloat = 12
  let cardSpacing: CGFloat = 8
  let cardCornerRadius: CGFloat = 10
  let panelPadding: CGFloat = 8
  let panelCornerRadius: CGFloat = 14
  let panelGap: CGFloat = 4
  let screenMargin: CGFloat = 8
  let lineSpacing: CGFloat = 6
  let headingSpacing: CGFloat = 5
  let captionSpacing: CGFloat = 2

  let headingFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
  let labelFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
  let valueFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
  let captionFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

  let valueEnd: CGFloat = 186
  let barWidth: CGFloat = 70
  let barHeight: CGFloat = 4
  let coreBarStart: CGFloat = 132
  let coreRowHeight: CGFloat = 18
  let coreGroupSpacing: CGFloat = 8
  let historyHeight: CGFloat = 36
  let historyBarSpacing: CGFloat = 1

  let staleAlpha: CGFloat = 0.4

  let cardFillAlpha: CGFloat = 0.05
  let cardOutlineAlpha: CGFloat = 0.08
  let trackAlpha: CGFloat = 0.12

  var cardWidth: CGFloat { contentWidth + 2 * cardPadding }

  let bar = NSColor.systemBlue
  let historyGradient = (bottom: NSColor.systemBlue, top: NSColor.systemTeal)

  func barColor(for value: DetailRow.Value) -> NSColor {
    guard value.unit == .celsius else { return bar }

    switch value.amount {
    case ..<40: return .systemBlue
    case ..<55: return .systemGreen
    case ..<70: return .systemYellow
    case ..<85: return .systemOrange
    default: return .systemRed
    }
  }
}
