import Foundation
import KernCore

struct DetailRow: Equatable {
  struct Value: Equatable {
    let amount: Int
    let unit: MetricUnit

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
    switch value?.unit {
    case nil: ""
    case .percent: "%"
    case .celsius: "°"
    }
  }

  var valueText: String { numberText + unitText }

  var spokenValue: String {
    guard let value else { return isMeasuring ? "measuring" : "unavailable" }

    switch value.unit {
    case .percent: return "\(value.amount) percent"
    case .celsius: return "\(value.amount) degrees Celsius"
    }
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

struct SensorRange: Equatable {
  let part: ChipPart
  let coolest: Double
  let hottest: Double

  init(_ temperature: PartTemperature) {
    part = temperature.part
    coolest = temperature.coolest
    hottest = temperature.hottest
  }

  var label: String {
    switch part {
    case .cpu: "CPU"
    }
  }

  var valueText: String { "\(Int(hottest.rounded()))°" }

  var spokenText: String {
    let (coolest, hottest) = (Int(coolest.rounded()), Int(hottest.rounded()))

    return coolest == hottest
      ? "\(label) sensors, \(hottest) degrees Celsius"
      : "\(label) sensors, \(coolest) to \(hottest) degrees Celsius"
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

struct HistoryChart: Equatable {
  let levels: [Double?]
  let span: Duration
  let unit: MetricUnit
  let isStale: Bool

  var spokenSummary: String {
    let values = levels.compactMap { $0 }
    let span = span.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    let unit = unit == .celsius ? "degrees Celsius" : "percent"

    guard let lowest = values.min(), let highest = values.max() else { return "No values in the last \(span)" }

    return "Last \(span): lowest \(Int(lowest.rounded())) \(unit), highest \(Int(highest.rounded())) \(unit)"
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
    }
  }

  func detailTitle(measuring quantity: MetricQuantity) -> String {
    let subject =
      switch self {
      case .cpu, .temperature: "CPU"
      case .gpu: "GPU"
      case .memory, .memoryPressure: "Memory"
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
    case .utilization, .activeResidency, .memoryUsage: nil
    }
  }

  func detailRow(for readings: MetricReadings, source: MetricSource, at now: ContinuousClock.Instant) -> DetailRow {
    let value = readings.lastSuccessful?.value
    let status: DetailRow.Status

    if let acquiredAt = readings.lastSuccessful?.acquiredAt {
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
      value: value.map { DetailRow.Value(amount: Int($0.value.rounded()), unit: $0.unit) },
      status: status
    )
  }

  func coreChart(for readings: MetricReadings, at now: ContinuousClock.Instant) -> CoreChart {
    CoreChart(cores: readings.lastSuccessful?.value?.cores, isStale: readings.isStale(at: now))
  }

  func historyChart(for readings: MetricReadings, at now: ContinuousClock.Instant) -> HistoryChart? {
    guard let history = readings.history else { return nil }

    return HistoryChart(
      levels: history.levels,
      span: readings.interval * history.capacity,
      unit: self == .temperature ? .celsius : .percent,
      isStale: readings.isStale(at: now)
    )
  }

  private static func measure(_ quantity: MetricQuantity) -> String {
    switch quantity {
    case .utilization: "Usage"
    case .activeResidency: "Activity"
    case .temperature: "Temperature"
    case .memoryUsage: "Used"
    case .memoryPressure: "Pressure"
    }
  }
}
