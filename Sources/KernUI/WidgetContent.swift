import KernCore

/// Must hold everything a widget draws, because a widget redraws only when its content changes.
enum WidgetContent: Equatable, CustomStringConvertible {
  case reading(String, isStale: Bool)
  /// Shows two short readings, one above the other.
  case stacked(String, String, isStale: Bool)
  /// Shows the dash of a widget that shows text but has no reading. It is never stale,
  /// because only a reading can be.
  case noReading
  case level(Level, isStale: Bool)
  /// Shows a level as a gauge followed by its percentage, or the gauge alone while there is no percentage.
  case levelReading(Level, isStale: Bool)
  case graph([Double?], isStale: Bool)
  /// Shows a bar for each level in percent, side by side in an outline, or the outline alone without levels.
  case bars([Double], isStale: Bool)

  enum Level: Equatable {
    case measuring
    case unavailable
    case percent(Int)
  }

  static let unavailableText = "—"

  var isStale: Bool {
    switch self {
    case .reading(_, let isStale), .stacked(_, _, let isStale), .level(_, let isStale), .levelReading(_, let isStale),
      .graph(_, let isStale), .bars(_, let isStale):
      isStale
    case .noReading: false
    }
  }

  var description: String {
    let stale = isStale ? ", stale" : ""

    switch self {
    case .reading(let text, _): return text + stale
    case .stacked(let top, let bottom, _): return "\(top) over \(bottom)" + stale
    case .noReading: return Self.unavailableText
    case .level(.measuring, _), .levelReading(.measuring, _): return "measuring" + stale
    case .level(.unavailable, _), .levelReading(.unavailable, _): return Self.unavailableText + stale
    case .level(.percent(let percent), _), .levelReading(.percent(let percent), _): return "\(percent)%" + stale
    case .graph(let levels, _): return "\(levels.count { $0 != nil }) values" + stale
    case .bars(let levels, _): return "\(levels.count) bars" + stale
    }
  }

  static func text(for value: MetricValue, temperatureUnit: TemperatureUnit) -> String {
    let unit = DisplayUnit(value.unit, temperatureUnit: temperatureUnit)

    return "\(Int(unit.amount(of: value.value).rounded()))\(unit.text)"
  }

  /// Keeps a tenth of a percent below 10%, where Kern's own use usually is, and drops it from 10% up,
  /// so the text is never wider than "888%".
  static func processCPUText(_ percent: Double) -> String {
    let tenths = (percent * 10).rounded() / 10

    return tenths < 10 ? String(format: "%.1f%%", tenths) : "\(Int(percent.rounded()))%"
  }

  /// Counts megabytes of 2^20 bytes, as Activity Monitor does.
  static func footprintText(_ bytes: UInt64) -> String {
    "\(Int((Double(bytes) / Double(1 << 20)).rounded())) MB"
  }
}

extension Widget {
  func content(
    for readings: MetricReadings,
    at now: ContinuousClock.Instant,
    temperatureUnit: TemperatureUnit
  ) -> WidgetContent {
    let isStale = readings.isStale(at: now)

    switch self {
    case .temperature:
      guard let value = readings.lastSuccessful?.value else { return .noReading }

      return .reading(WidgetContent.text(for: value, temperatureUnit: temperatureUnit), isStale: isStale)

    case .kern:
      guard let value = readings.lastSuccessful?.value, let footprint = value.footprintBytes else { return .noReading }

      return .stacked(
        WidgetContent.processCPUText(value.value), WidgetContent.footprintText(footprint), isStale: isStale)

    case .gpu, .memory:
      return .level(Self.level(of: readings), isStale: isStale)

    case .storage:
      return .levelReading(Self.level(of: readings), isStale: isStale)

    case .cpu:
      guard let history = readings.history else { preconditionFailure("\(metric) keeps no history to draw") }

      return .graph(history.levels, isStale: isStale)

    case .cores:
      let cores = readings.lastSuccessful?.value?.cores

      return .bars(cores.map { $0.performance + $0.efficiency } ?? [], isStale: isStale)
    }
  }

  private static func level(of readings: MetricReadings) -> WidgetContent.Level {
    if let value = readings.lastSuccessful?.value {
      return .percent(Int(value.value.rounded()))
    }

    switch readings.latest?.state {
    case nil, .unavailable(.noValue(.awaitingBaseline)): return .measuring
    default: return .unavailable
    }
  }
}
