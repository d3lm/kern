public struct SourceID: Hashable, Sendable, CustomStringConvertible {
  public let rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue }
}

public struct MetricSource: Equatable, Sendable {
  public let id: SourceID
  public let quantity: MetricQuantity
  public let description: String
  public let coreKinds: [CoreKind]?

  public init(id: SourceID, quantity: MetricQuantity, description: String, coreKinds: [CoreKind]? = nil) {
    self.id = id
    self.quantity = quantity
    self.description = description
    self.coreKinds = coreKinds
  }
}

public enum MetricUnit: Sendable {
  case percent
  case celsius
}

public enum MetricQuantity: Sendable {
  case utilization
  case activeResidency
  case temperature
  case memoryUsage
  case memoryPressure
}

public struct MetricValue: Equatable, Sendable {
  public let value: Double
  public let unit: MetricUnit
  public let cores: CoreUtilization?
  public let split: CPUTimeSplit?

  public init(_ value: Double, _ unit: MetricUnit, cores: CoreUtilization? = nil, split: CPUTimeSplit? = nil) {
    self.value = value
    self.unit = unit
    self.cores = cores
    self.split = split
  }
}

public struct CPUTimeSplit: Equatable, Sendable {
  public let user: Double
  public let system: Double

  public init(user: Double, system: Double) {
    self.user = user
    self.system = system
  }
}

public struct CoreUtilization: Equatable, Sendable {
  public let performance: [Double]
  public let efficiency: [Double]

  public init(performance: [Double], efficiency: [Double]) {
    self.performance = performance
    self.efficiency = efficiency
  }
}

public enum NoValueReason: Equatable, Sendable {
  case awaitingBaseline
  case countersUnchanged
  case countersWentBackwards
}

public enum UnavailableReason: Equatable, Sendable {
  case notStarted
  case noValue(NoValueReason)
  case sensorFailed(SensorError)
}

public enum SampleState: Equatable, Sendable {
  case valid(MetricValue)
  case unavailable(UnavailableReason)
}

public struct MetricSample: Equatable, Sendable {
  public let source: SourceID
  public let quantity: MetricQuantity
  /// Must keep running during system sleep, so a reading taken before sleep is stale after wake.
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
