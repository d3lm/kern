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
  /// Uses a clock that keeps running during system sleep, so a reading taken before sleep is old after wake.
  public let acquiredAt: ContinuousClock.Instant
  public let state: SampleState

  public init(source: SourceID, acquiredAt: ContinuousClock.Instant, state: SampleState) {
    self.source = source
    self.acquiredAt = acquiredAt
    self.state = state
  }

  public var value: MetricValue? {
    if case .valid(let value) = state { value } else { nil }
  }
}
