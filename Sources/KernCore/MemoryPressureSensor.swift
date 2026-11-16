import Darwin

protocol MemoryAvailabilitySource: Sendable {
  func availablePercent() throws(SensorError) -> Int
}

public struct MemoryPressureSensor: MetricSensor {
  public let source = SourceID("memory.memorystatus_level")
  public let quantity = MetricQuantity.memoryPressure
  public let sourceDescription = "Memory macOS must reclaim before giving it to an app, from kern.memorystatus_level"
  public let coreKinds: [CoreKind]? = nil
  private let availability: any MemoryAvailabilitySource

  public init() {
    self.init(availability: SysctlMemoryAvailability())
  }

  init(availability: some MemoryAvailabilitySource) {
    self.availability = availability
  }

  /// Reads once so that a system without the sysctl fails to open rather than failing every read.
  public mutating func open() throws(SensorError) {
    _ = try availablePercent()
  }

  public mutating func read() throws(SensorError) -> SensorReading {
    .value(MetricValue(Double(100 - (try availablePercent())), .percent))
  }

  public mutating func close() {}

  private func availablePercent() throws(SensorError) -> Int {
    let percent = try availability.availablePercent()

    guard (0...100).contains(percent) else {
      throw SensorError("the available memory reads as \(percent)%, outside 0–100%")
    }

    return percent
  }
}

struct SysctlMemoryAvailability: MemoryAvailabilitySource {
  func availablePercent() throws(SensorError) -> Int {
    var level: Int32 = 0
    var size = MemoryLayout<Int32>.size

    guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size else {
      throw SensorError("sysctl kern.memorystatus_level failed: \(String(cString: strerror(errno)))")
    }

    return Int(level)
  }
}
