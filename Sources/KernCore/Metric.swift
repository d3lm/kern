public enum Metric: String, CaseIterable, Sendable {
  case cpu
  case gpu
  case temperature
  case memory
  case memoryPressure = "memory-pressure"
  /// Is the share of the startup disk in use.
  case storage
  /// Is Kern's own CPU and memory use.
  case kern

  public var defaultInterval: Duration {
    switch self {
    case .cpu, .gpu, .kern: .seconds(2)
    case .memory, .memoryPressure: .seconds(5)
    case .temperature, .storage: .seconds(10)
    }
  }

  public var lowPowerInterval: Duration {
    switch self {
    case .cpu, .gpu, .kern: .seconds(5)
    case .temperature, .storage: .seconds(20)
    case .memory, .memoryPressure: .seconds(10)
    }
  }

  var keepsHistory: Bool {
    switch self {
    case .cpu, .gpu, .temperature, .memoryPressure: true
    case .memory, .storage, .kern: false
    }
  }

  var isSampledOnlyForDetails: Bool {
    switch self {
    case .memory: true
    case .cpu, .gpu, .temperature, .memoryPressure, .storage, .kern: false
    }
  }
}
