import Foundation
import KernCore

enum DisplayUnit: Equatable {
  case percent
  case degrees(TemperatureUnit)

  init(_ unit: MetricUnit, temperatureUnit: TemperatureUnit) {
    switch unit {
    case .percent: self = .percent
    case .celsius: self = .degrees(temperatureUnit)
    }
  }

  var text: String {
    switch self {
    case .percent: "%"
    case .degrees: "°"
    }
  }

  var spokenName: String {
    switch self {
    case .percent: "percent"
    case .degrees(let unit): unit.spokenName
    }
  }

  /// Converts a value measured in the metric's own unit, which for a temperature is degrees Celsius.
  func amount(of measured: Double) -> Double {
    switch self {
    case .percent: measured
    case .degrees(let unit): unit.value(ofCelsius: measured)
    }
  }
}

struct DetailRow: Equatable {
  struct Value: Equatable {
    let amount: Int
    let unit: DisplayUnit

    var fraction: Double {
      min(max(Double(amount) / 100, 0), 1)
    }
  }

  enum Status: Equatable {
    case current(acquiredAt: ContinuousClock.Instant)
    case stale(acquiredAt: ContinuousClock.Instant)
    case waiting
    case noValue(NoValueReason)
    case failed(SensorError)
    case off
  }

  let title: String
  let label: String
  let explanation: String?
  let value: Value?
  let status: Status

  var isStale: Bool {
    if case .stale = status { true } else { false }
  }

  var isMeasuring: Bool {
    status == .waiting || status == .noValue(.awaitingBaseline)
  }

  var numberText: String {
    value.map { "\($0.amount)" } ?? WidgetContent.unavailableText
  }

  var unitText: String {
    value?.unit.text ?? ""
  }

  var valueText: String { numberText + unitText }

  var spokenValue: String {
    guard let value else { return isMeasuring ? "measuring" : "unavailable" }

    return "\(value.amount) \(value.unit.spokenName)"
  }

  func statusText(at now: ContinuousClock.Instant, date: Date, timeStyle: Date.FormatStyle) -> String? {
    func time(of instant: ContinuousClock.Instant) -> String {
      let (seconds, attoseconds) = instant.duration(to: now).components
      let age = TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18

      return date.addingTimeInterval(-age).formatted(timeStyle)
    }

    guard !isMeasuring else { return nil }

    switch status {
    case .current, .waiting, .noValue(.awaitingBaseline): return nil
    case .stale(let acquiredAt): return "Stale: not updated since \(time(of: acquiredAt))"
    case .noValue(.countersUnchanged): return "No value: the counters did not advance"
    case .noValue(.countersWentBackwards): return "No value: the counters went backwards"
    case .failed(let error): return "Unavailable: \(error)"
    case .off: return "Turned off in Settings"
    }
  }
}

/// Used memory in gigabytes as Activity Monitor counts them, 2^30 bytes each.
struct MemoryText: Equatable {
  let used: String
  let installed: String

  init(_ amount: MemoryAmount) {
    func gigabytes(_ bytes: UInt64) -> Double {
      Double(bytes) / Double(1 << 30)
    }

    let installed = gigabytes(amount.installedBytes)

    self.used = String(format: "%.1f", gigabytes(amount.usedBytes))
    self.installed = installed == installed.rounded() ? "\(Int(installed))" : String(format: "%.1f", installed)
  }

  var text: String { "\(used) / \(installed) GB" }
  var spokenText: String { "\(used) of \(installed) gigabytes" }
}

/// Holds the range in degrees Celsius, which its bar is drawn on, and says it in the unit of the settings.
struct SensorRange: Equatable {
  let part: ChipPart
  let coolest: Double
  let hottest: Double
  let unit: TemperatureUnit

  init(_ temperature: PartTemperature, unit: TemperatureUnit) {
    part = temperature.part
    coolest = temperature.coolest
    hottest = temperature.hottest
    self.unit = unit
  }

  var label: String {
    switch part {
    case .cpu: "CPU"
    }
  }

  private func shown(_ celsius: Double) -> Int {
    Int(unit.value(ofCelsius: celsius).rounded())
  }

  var valueText: String { "\(shown(hottest))°" }

  var spokenText: String {
    let (coolest, hottest) = (shown(coolest), shown(hottest))

    return coolest == hottest
      ? "\(label) sensors, \(hottest) \(unit.spokenName)"
      : "\(label) sensors, \(coolest) to \(hottest) \(unit.spokenName)"
  }
}

struct CoreChart: Equatable {
  let cores: CoreUtilization?
  let isStale: Bool

  var spokenSummary: String {
    guard let cores else { return "unavailable" }

    func list(_ shares: [Double]) -> String {
      shares.map { "\(Int($0.rounded()))" }.joined(separator: ", ") + " percent"
    }

    return [
      cores.performance.isEmpty ? nil : "Performance cores: \(list(cores.performance))",
      cores.efficiency.isEmpty ? nil : "Efficiency cores: \(list(cores.efficiency))",
    ].compactMap { $0 }.joined(separator: ". ")
  }

  static func mean(_ shares: [Double]) -> Int? {
    shares.isEmpty ? nil : Int((shares.reduce(0, +) / Double(shares.count)).rounded())
  }
}

/// Holds the levels as measured, which for a temperature is degrees Celsius, and says them in `unit`.
struct HistoryChart: Equatable {
  let levels: [Double?]
  let span: Duration
  let unit: DisplayUnit
  let isStale: Bool

  var spokenSummary: String {
    let values = levels.compactMap { $0 }
    let span = span.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))

    func said(_ level: Double) -> String {
      "\(Int(unit.amount(of: level).rounded())) \(unit.spokenName)"
    }

    guard let lowest = values.min(), let highest = values.max() else { return "No values in the last \(span)" }

    return "Last \(span): lowest \(said(lowest)), highest \(said(highest))"
  }
}

extension ChipIdentity {
  /// The chip as the panel's header names it, without the "Apple" every brand string starts with.
  var name: String? {
    switch self {
    case .recognized(let chip): chip.description
    case .unrecognized(let brandString?): brandString.replacing(#/^Apple /#, with: "")
    case .unrecognized(nil): nil
    }
  }
}

extension Metric {
  /// Memory pressure comes first in its card, because its number and chart head it and used memory is a row below.
  static let detailOrder: [Metric] = [.cpu, .gpu, .temperature, .memoryPressure, .memory]

  var detailHeading: String {
    switch self {
    case .cpu: "CPU"
    case .gpu: "GPU"
    case .temperature: "Temperature"
    case .memory, .memoryPressure: "Memory"
    case .kern: "Kern"
    }
  }

  func detailTitle(measuring quantity: MetricQuantity) -> String {
    let subject =
      switch self {
      case .cpu, .temperature: "CPU"
      case .gpu: "GPU"
      case .memory, .memoryPressure: "Memory"
      case .kern: "Kern"
      }

    return "\(subject) \(Self.measure(quantity).lowercased())"
  }

  func detailLabel(measuring quantity: MetricQuantity) -> String {
    quantity == .temperature ? "CPU" : Self.measure(quantity)
  }

  func detailExplanation(of source: MetricSource) -> String {
    source.quantity == .activeResidency
      ? "Active residency: the share of time it was powered on, not utilization"
      : source.description
  }

  /// What the card's large number is, where the heading alone does not say it.
  func detailCaption(measuring quantity: MetricQuantity) -> String? {
    switch quantity {
    case .temperature: "hottest CPU sensor"
    case .memoryPressure: "memory pressure"
    case .utilization, .activeResidency, .memoryUsage, .processUsage: nil
    }
  }

  func detailRow(
    for readings: MetricReadings,
    source: MetricSource,
    at now: ContinuousClock.Instant,
    temperatureUnit: TemperatureUnit
  ) -> DetailRow {
    let value = readings.lastSuccessful?.value
    let status: DetailRow.Status

    if !readings.isEnabled {
      status = .off
    } else if let acquiredAt = readings.lastSuccessful?.acquiredAt {
      status = readings.isStale(at: now) ? .stale(acquiredAt: acquiredAt) : .current(acquiredAt: acquiredAt)
    } else {
      switch readings.latest?.state {
      case nil, .valid, .unavailable(.notStarted): status = .waiting
      case .unavailable(.noValue(let reason)): status = .noValue(reason)
      case .unavailable(.sensorFailed(let error)): status = .failed(error)
      }
    }

    let split = value?.split.map {
      "User \(Int($0.user.rounded()))% (apps), system \(Int($0.system.rounded()))% (macOS kernel)"
    }

    return DetailRow(
      title: detailTitle(measuring: source.quantity),
      label: detailLabel(measuring: source.quantity),
      explanation: [detailExplanation(of: source), split].compactMap { $0 }.joined(separator: "\n"),
      value: value.map { value in
        let unit = DisplayUnit(value.unit, temperatureUnit: temperatureUnit)

        return DetailRow.Value(amount: Int(unit.amount(of: value.value).rounded()), unit: unit)
      },
      status: status
    )
  }

  func coreChart(for readings: MetricReadings, at now: ContinuousClock.Instant) -> CoreChart {
    CoreChart(cores: readings.lastSuccessful?.value?.cores, isStale: readings.isStale(at: now))
  }

  func historyChart(
    for readings: MetricReadings,
    at now: ContinuousClock.Instant,
    temperatureUnit: TemperatureUnit
  ) -> HistoryChart? {
    guard let history = readings.history else { return nil }

    return HistoryChart(
      levels: history.levels,
      span: readings.interval * history.capacity,
      unit: self == .temperature ? .degrees(temperatureUnit) : .percent,
      isStale: readings.isStale(at: now)
    )
  }

  private static func measure(_ quantity: MetricQuantity) -> String {
    switch quantity {
    case .utilization, .processUsage: "Usage"
    case .activeResidency: "Activity"
    case .temperature: "Temperature"
    case .memoryUsage: "Used"
    case .memoryPressure: "Pressure"
    }
  }
}
