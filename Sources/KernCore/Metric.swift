public enum Metric: String, CaseIterable, Sendable {
  case cpu
  case gpu
  case temperature
  case memory
  case memoryPressure = "memory-pressure"

  public var defaultInterval: Duration {
    switch self {
    case .cpu, .gpu: .seconds(2)
    case .memory, .memoryPressure: .seconds(5)
    case .temperature: .seconds(10)
    }
  }

  var keepsHistory: Bool {
    switch self {
    case .cpu, .gpu: true
    case .temperature, .memory, .memoryPressure: false
    }
  }

  var isSampledOnlyForDetails: Bool {
    switch self {
    case .memory: true
    case .cpu, .gpu, .temperature, .memoryPressure: false
    }
  }
}
