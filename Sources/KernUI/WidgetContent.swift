import KernCore

/// What a widget shows at one moment. Equal contents draw the same pixels, so a widget redraws only when
/// its content changes.
enum WidgetContent: Equatable, CustomStringConvertible {
  /// The last successful value, or `—` when there is none.
  case reading(String, isStale: Bool)

  /// The last successful value in whole percent, or `nil` when there is none.
  case level(Int?, isStale: Bool)

  /// One level in percent for each slot of the history, oldest first. `nil` is a slot without a value.
  /// A gap, or a slot not yet filled.
  case graph([Double?], isStale: Bool)

  static let unavailableText = "—"

  var isStale: Bool {
    switch self {
    case .reading(_, let isStale), .level(_, let isStale), .graph(_, let isStale): isStale
    }
  }

  /// The same content once its value has gone stale. Only staleness changes with time alone.
  /// Everything else changes only with a new sample.
  var markedStale: WidgetContent {
    switch self {
    case .reading(let text, _): .reading(text, isStale: true)
    case .level(let percent, _): .level(percent, isStale: true)
    case .graph(let levels, _): .graph(levels, isStale: true)
    }
  }

  var description: String {
    let stale = isStale ? ", stale" : ""

    switch self {
    case .reading(let text, _): return text + stale
    case .level(let percent, _): return (percent.map { "\($0)%" } ?? Self.unavailableText) + stale
    case .graph(let levels, _): return "\(levels.count { $0 != nil }) values" + stale
    }
  }

  static func text(for value: MetricValue) -> String {
    let rounded = Int(value.value.rounded())

    switch value.unit {
    case .celsius: return "\(rounded)°"
    case .percent: return "\(rounded)%"
    }
  }
}

extension Widget {
  func content(for readings: MetricReadings, at now: ContinuousClock.Instant) -> WidgetContent {
    let isStale = readings.isStale(at: now)

    switch self {
    case .temperature:
      let text = readings.lastSuccessful?.value.map(WidgetContent.text) ?? WidgetContent.unavailableText

      return .reading(text, isStale: isStale)

    case .gpu, .memory:
      return .level(readings.lastSuccessful?.value.map { Int($0.value.rounded()) }, isStale: isStale)

    case .cpu:
      guard let history = readings.history else { preconditionFailure("\(metric) keeps no history to draw") }

      let empty = [Double?](repeating: nil, count: history.capacity - history.count)

      return .graph(empty + history.map { $0.value?.value }, isStale: isStale)
    }
  }
}
