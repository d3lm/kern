import Foundation
import KernCore

enum DetailLine: Equatable {
  case value
  case userTime
  case systemTime
}

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

  let line: DetailLine
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

  var valueText: String {
    guard let value else { return WidgetContent.unavailableText }

    switch value.unit {
    case .percent: return "\(value.amount)%"
    case .celsius: return "\(value.amount) °C"
    }
  }

  var spokenValue: String {
    guard let value else { return isMeasuring ? "measuring" : "unavailable" }

    switch value.unit {
    case .percent: return "\(value.amount) percent"
    case .celsius: return "\(value.amount) degrees Celsius"
    }
  }

  var markedStale: DetailRow {
    guard case .current(let acquiredAt) = status else { return self }

    return DetailRow(
      line: line,
      title: title,
      label: label,
      explanation: explanation,
      value: value,
      status: .stale(acquiredAt: acquiredAt)
    )
  }

  func statusText(at now: ContinuousClock.Instant, date: Date, timeStyle: Date.FormatStyle) -> String? {
    func time(of instant: ContinuousClock.Instant) -> String {
      let (seconds, attoseconds) = instant.duration(to: now).components
      let age = TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
      return date.addingTimeInterval(-age).formatted(timeStyle)
    }

    guard line == .value, !isMeasuring else { return nil }

    switch status {
    case .current, .waiting, .noValue(.awaitingBaseline): return nil
    case .stale(let acquiredAt): return "Stale: not updated since \(time(of: acquiredAt))"
    case .noValue(.countersUnchanged): return "No value: the counters did not advance"
    case .noValue(.countersWentBackwards): return "No value: the counters went backwards"
    case .failed(let error): return "Unavailable: \(error)"
    }
  }
}

struct CoreChart: Equatable {
  let cores: CoreUtilization?
  let isStale: Bool

  var markedStale: CoreChart {
    CoreChart(cores: cores, isStale: true)
  }

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
}

struct HistoryChart: Equatable {
  let levels: [Double?]
  let span: Duration
  let isStale: Bool

  var markedStale: HistoryChart {
    HistoryChart(levels: levels, span: span, isStale: true)
  }

  var spokenSummary: String {
    let values = levels.compactMap { $0 }
    let span = span.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))

    guard let lowest = values.min(), let highest = values.max() else { return "No values in the last \(span)" }

    return "Last \(span): lowest \(Int(lowest.rounded())) percent, highest \(Int(highest.rounded())) percent"
  }
}

extension Metric {
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

  var detailLines: [DetailLine] {
    self == .cpu ? [.value, .userTime, .systemTime] : [.value]
  }

  func detailRow(
    _ line: DetailLine = .value,
    for readings: MetricReadings,
    source: MetricSource,
    at now: ContinuousClock.Instant
  ) -> DetailRow {
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

    func row(title: String, label: String, explanation: String?, amount: Double?) -> DetailRow {
      DetailRow(
        line: line,
        title: title,
        label: label,
        explanation: explanation,
        value: value.flatMap { value in
          amount.map {
            DetailRow.Value(
              amount: Int($0.rounded()),
              unit: value.unit
            )
          }
        },
        status: status
      )
    }

    switch line {
    case .value:
      return row(
        title: detailTitle(measuring: source.quantity),
        label: detailLabel(measuring: source.quantity),
        explanation: source.quantity == .activeResidency
          ? "Active residency: the share of time it was powered on, not utilization"
          : source.description,
        amount: value?.value
      )

    case .userTime:
      return row(
        title: "CPU user time",
        label: "User",
        explanation: "Time running apps",
        amount: value?.split?.user
      )

    case .systemTime:
      return row(
        title: "CPU system time",
        label: "System",
        explanation: "Time running the macOS kernel",
        amount: value?.split?.system
      )
    }
  }

  func coreChart(for readings: MetricReadings, at now: ContinuousClock.Instant) -> CoreChart {
    CoreChart(cores: readings.lastSuccessful?.value?.cores, isStale: readings.isStale(at: now))
  }

  func historyChart(for readings: MetricReadings, at now: ContinuousClock.Instant) -> HistoryChart? {
    guard let history = readings.history else { return nil }

    return HistoryChart(
      levels: history.levels,
      span: readings.interval * history.capacity,
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
