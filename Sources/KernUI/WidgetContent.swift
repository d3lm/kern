import KernCore

/// Must hold everything a widget draws, because a widget redraws only when its content changes.
enum WidgetContent: Equatable, CustomStringConvertible {
  case reading(String, isStale: Bool)
  case level(Level, isStale: Bool)
  case graph([Double?], isStale: Bool)

  enum Level: Equatable {
    case measuring
    case unavailable
    case percent(Int)
  }

  static let unavailableText = "—"

  var isStale: Bool {
    switch self {
    case .reading(_, let isStale), .level(_, let isStale), .graph(_, let isStale): isStale
    }
  }

  var description: String {
    let stale = isStale ? ", stale" : ""

    switch self {
    case .reading(let text, _): return text + stale
    case .level(.measuring, _): return "measuring" + stale
    case .level(.unavailable, _): return Self.unavailableText + stale
    case .level(.percent(let percent), _): return "\(percent)%" + stale
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
      if let value = readings.lastSuccessful?.value {
        return .level(.percent(Int(value.value.rounded())), isStale: isStale)
      }

      switch readings.latest?.state {
      case nil, .unavailable(.noValue(.awaitingBaseline)): return .level(.measuring, isStale: isStale)
      default: return .level(.unavailable, isStale: isStale)
      }

    case .cpu:
      guard let history = readings.history else { preconditionFailure("\(metric) keeps no history to draw") }

      return .graph(history.levels, isStale: isStale)
    }
  }
}
