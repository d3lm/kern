import AppKit
import KernCore

struct MenuBarStyle {
  let valueFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
  let labelFont = NSFont.systemFont(ofSize: 6.5, weight: .bold)
  let labelLineHeight: CGFloat = 6
  let labelSpacing: CGFloat = 3
  let widgetSpacing: CGFloat = 8
  let height: CGFloat = 18
  let chartWidth: CGFloat = 36
  let gaugeWidth: CGFloat = 7
  let outlineWidth: CGFloat = 1
  let chartPadding: CGFloat = 1
  let chartSmoothing = 2
  let cornerRadius: CGFloat = 3
  let placeholderSymbol = "gauge.with.dots.needle.33percent"
  let placeholderPointSize: CGFloat = 14

  let valueAlpha: CGFloat = 1
  let staleAlpha: CGFloat = 0.4
  let outlineAlpha: CGFloat = 0.45
  let trackAlpha: CGFloat = 0.25

  func textWidth(_ text: String, in font: NSFont) -> CGFloat {
    ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
  }

  func labelWidth(_ label: String) -> CGFloat {
    label.map { textWidth(String($0), in: labelFont) }.max() ?? 0
  }

  func valueWidth(of widget: Widget) -> CGFloat {
    switch widget {
    case .temperature: max(textWidth(WidgetContent.unavailableText, in: valueFont), textWidth("888°", in: valueFont))
    case .cpu: chartWidth
    case .gpu, .memory: gaugeWidth
    }
  }

  func valueOffset(label: String?) -> CGFloat {
    label.map { labelWidth($0) + labelSpacing } ?? 0
  }

  func width(of widget: Widget, label: String?) -> CGFloat {
    valueOffset(label: label) + valueWidth(of: widget)
  }
}
