/// What Kern measures, independent of the sensor that measures it. Everything above the providers refers to metrics,
/// so a sensor can be replaced without touching anything that reads its readings.
public enum Metric: String, CaseIterable, Sendable {
  case cpu
  case gpu
  case temperature
  case memoryPressure = "memory-pressure"

  public var defaultInterval: Duration {
    switch self {
    case .cpu, .gpu: .seconds(2)
    case .memoryPressure: .seconds(5)
    case .temperature: .seconds(10)
    }
  }

  var keepsHistory: Bool {
    switch self {
    case .cpu, .gpu: true
    case .temperature, .memoryPressure: false
    }
  }
}
