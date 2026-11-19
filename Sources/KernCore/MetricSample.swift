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
  /// Is the share of a disk's capacity that is not available for new files, where space macOS would free by
  /// purging caches counts as available.
  case storageUsage
  /// Is the CPU use of one process on the scale of Activity Monitor's % CPU, where 100% is one busy logical CPU.
  case processUsage
}

public struct MetricValue: Equatable, Sendable {
  public let value: Double
  public let unit: MetricUnit
  public let cores: CoreUtilization?
  public let split: CPUTimeSplit?
  public let memory: MemoryAmount?
  public let temperatures: [PartTemperature]?
  /// Holds a process's physical footprint in bytes, which Activity Monitor shows as its Memory.
  public let footprintBytes: UInt64?

  public init(
    _ value: Double,
    _ unit: MetricUnit,
    cores: CoreUtilization? = nil,
    split: CPUTimeSplit? = nil,
    memory: MemoryAmount? = nil,
    temperatures: [PartTemperature]? = nil,
    footprintBytes: UInt64? = nil
  ) {
    self.value = value
    self.unit = unit
    self.cores = cores
    self.split = split
    self.memory = memory
    self.temperatures = temperatures
    self.footprintBytes = footprintBytes
  }
}

public struct MemoryAmount: Equatable, Sendable {
  public let usedBytes: UInt64
  public let installedBytes: UInt64

  public init(usedBytes: UInt64, installedBytes: UInt64) {
    self.usedBytes = usedBytes
    self.installedBytes = installedBytes
  }
}

public enum ChipPart: Equatable, Sendable {
  case cpu
}

/// The coolest and hottest of the sensors read for one part of the chip.
public struct PartTemperature: Equatable, Sendable {
  public let part: ChipPart
  public let coolest: Double
  public let hottest: Double

  public init(part: ChipPart, coolest: Double, hottest: Double) {
    self.part = part
    self.coolest = coolest
    self.hottest = hottest
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
