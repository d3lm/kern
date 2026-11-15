import AppKit
import KernCore

/// The fonts, sizes, and opacities of the menu bar. A widget's width depends only on these and the layout, never on
/// the value it shows, so a changing value cannot move its neighbors.
///
/// Everything is drawn in the system label color, at these opacities.
struct MenuBarStyle {
  /// The menu bar's own font size, with digits of equal width, so that a number keeps its width as its digits change.
  let valueFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
  /// Small enough for three letters stacked on top of each other within the height of a chart.
  let labelFont = NSFont.systemFont(ofSize: 6.5, weight: .bold)
  /// From the baseline of one stacked letter to the next.
  let labelLineHeight: CGFloat = 6
  let labelSpacing: CGFloat = 3
  let widgetSpacing: CGFloat = 8
  let height: CGFloat = 18
  let chartWidth: CGFloat = 36
  let gaugeWidth: CGFloat = 7
  let outlineWidth: CGFloat = 1
  /// Between the chart's outline and the area inside it.
  let chartPadding: CGFloat = 1
  /// The chart draws each sample as the mean of itself and up to this many samples on either side, ten seconds in
  /// all at the default interval. The 2-second samples of a busy desktop swing by tens of points, and drawn as they
  /// are the chart is a row of spikes that hides the trend it is there to show.
  let chartSmoothing = 2
  let cornerRadius: CGFloat = 3

  let valueAlpha: CGFloat = 1
  let staleAlpha: CGFloat = 0.4
  let outlineAlpha: CGFloat = 0.45
  /// The empty part of the gauge, so that its extent shows at a low level.
  let trackAlpha: CGFloat = 0.25

  func textWidth(_ text: String, in font: NSFont) -> CGFloat {
    ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
  }

  /// The label's letters stack in one column as wide as the widest of them.
  func labelWidth(_ label: String) -> CGFloat {
    label.map { textWidth(String($0), in: labelFont) }.max() ?? 0
  }

  /// Room for the widest value the widget can show. A temperature has at most three digits, even in Fahrenheit,
  /// and every digit has the same width.
  func valueWidth(of widget: Widget) -> CGFloat {
    switch widget {
    case .temperature: max(textWidth(WidgetContent.unavailableText, in: valueFont), textWidth("888°", in: valueFont))
    case .cpu: chartWidth
    case .gpu, .memory: gaugeWidth
    }
  }

  /// Where the value starts: after the label and its spacing, or at the leading edge without a label.
  func valueOffset(label: String?) -> CGFloat {
    label.map { labelWidth($0) + labelSpacing } ?? 0
  }

  func width(of widget: Widget, label: String?) -> CGFloat {
    valueOffset(label: label) + valueWidth(of: widget)
  }
}
