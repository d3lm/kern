public struct SourceID: Hashable, Sendable, CustomStringConvertible {
  public let rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue }
}

public enum MetricUnit: Sendable {
  case percent
  case celsius
}

/// What a number measures. Two percentages can mean different things, and the UI must label each one by what it is.
public enum MetricQuantity: Sendable {
  /// The share of time the hardware was busy doing work.
  case utilization
  /// The share of time the hardware was powered in an active state. Hardware can be active without doing work, so
  /// this is never presented as utilization.
  case activeResidency
  case temperature
  /// The share of installed memory in use by apps and the system, as Activity Monitor counts its Memory Used.
  case memoryUsage
}

public struct MetricValue: Equatable, Sendable {
  public let value: Double
  public let unit: MetricUnit

  public init(_ value: Double, _ unit: MetricUnit) {
    self.value = value
    self.unit = unit
  }
}

/// Why a sensor that read its source without error still has no value.
public enum NoValueReason: Equatable, Sendable {
  /// The value is a rate between two readings, and there is no earlier reading to compare with yet.
  case awaitingBaseline
  /// The source's counters have not advanced since the previous reading.
  case countersUnchanged
  /// A counter is lower than at the previous reading.
  case countersWentBackwards
}

public enum UnavailableReason: Equatable, Sendable {
  case notStarted
  case noValue(NoValueReason)
  case sensorFailed(SensorError)
}

/// An unavailable sample has no number, so it cannot be mistaken for a reading of zero.
public enum SampleState: Equatable, Sendable {
  case valid(MetricValue)
  case unavailable(UnavailableReason)
}

public struct MetricSample: Equatable, Sendable {
  public let source: SourceID
  public let quantity: MetricQuantity
  /// Uses a clock that keeps running during system sleep, so a reading taken before sleep is old after wake.
  public let acquiredAt: ContinuousClock.Instant
  public let state: SampleState

  public init(source: SourceID, quantity: MetricQuantity, acquiredAt: ContinuousClock.Instant, state: SampleState) {
    self.source = source
    self.quantity = quantity
    self.acquiredAt = acquiredAt
    self.state = state
  }

  public var value: MetricValue? {
    if case .valid(let value) = state { value } else { nil }
  }
}
